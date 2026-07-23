// Copyright 2019 The Chromium OS Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Calf patch: poll every virtqueue and run one host thread per queue so guest
// multi-queue FUSE READs (readahead) are not serialized on a single worker.

#[cfg(target_os = "macos")]
use crossbeam_channel::Sender;
#[cfg(target_os = "macos")]
use utils::worker_message::WorkerMessage;

use std::io;
use std::os::fd::AsRawFd;
use std::sync::atomic::AtomicI32;
use std::sync::Arc;
use std::thread;

use utils::epoll::{ControlOperation, Epoll, EpollEvent, EventSet};
use utils::eventfd::EventFd;
use vm_memory::GuestMemoryMmap;

use super::super::{FsError, Queue};
use super::augment_fs::AugmentFs;
#[allow(unused_imports)]
use super::defs::{HPQ_INDEX, REQ_INDEX};
use super::descriptor_utils::{Reader, Writer};
use super::inode_alloc::InodeAllocator;
use super::null_fs::NullFs;
use super::passthrough::{self, PassthroughFs};
use super::read_only::PassthroughFsRo;
use super::server::Server;
use super::virtual_entry::VirtualDirEntry;
use crate::virtio::{InterruptTransport, VirtioShmRegion};

enum FsServer {
    ReadWrite(Server<AugmentFs<PassthroughFs>>),
    ReadOnly(Server<AugmentFs<PassthroughFsRo>>),
    Null(Server<AugmentFs<NullFs>>),
}

impl FsServer {
    fn handle_message(
        &self,
        r: Reader,
        w: Writer,
        allow_idmap: bool,
        shm_region: &Option<VirtioShmRegion>,
        exit_code: &Arc<AtomicI32>,
        #[cfg(target_os = "macos")] map_sender: &Option<Sender<WorkerMessage>>,
    ) -> super::Result<usize> {
        match self {
            FsServer::ReadWrite(s) => s.handle_message(
                r,
                w,
                allow_idmap,
                shm_region,
                exit_code,
                #[cfg(target_os = "macos")]
                map_sender,
            ),
            FsServer::ReadOnly(s) => s.handle_message(
                r,
                w,
                allow_idmap,
                shm_region,
                exit_code,
                #[cfg(target_os = "macos")]
                map_sender,
            ),
            FsServer::Null(s) => s.handle_message(
                r,
                w,
                allow_idmap,
                shm_region,
                exit_code,
                #[cfg(target_os = "macos")]
                map_sender,
            ),
        }
    }
}

pub struct FsWorker {
    queues: Vec<Queue>,
    queue_evts: Vec<Arc<EventFd>>,
    interrupt: InterruptTransport,
    mem: GuestMemoryMmap,
    allow_idmap: bool,
    shm_region: Option<VirtioShmRegion>,
    server: FsServer,
    stop_fd: EventFd,
    exit_code: Arc<AtomicI32>,
    #[cfg(target_os = "macos")]
    map_sender: Option<Sender<WorkerMessage>>,
}

impl FsWorker {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        queues: Vec<Queue>,
        queue_evts: Vec<Arc<EventFd>>,
        interrupt: InterruptTransport,
        mem: GuestMemoryMmap,
        allow_idmap: bool,
        shm_region: Option<VirtioShmRegion>,
        passthrough_cfg: Option<passthrough::Config>,
        read_only: bool,
        virtual_entries: Vec<VirtualDirEntry>,
        stop_fd: EventFd,
        exit_code: Arc<AtomicI32>,
        #[cfg(target_os = "macos")] map_sender: Option<Sender<WorkerMessage>>,
    ) -> Result<Self, io::Error> {
        let inode_alloc = Arc::new(InodeAllocator::new());
        let server = match passthrough_cfg {
            Some(cfg) if read_only => {
                let inner = PassthroughFsRo::new(cfg, inode_alloc.clone())?;
                FsServer::ReadOnly(Server::new(AugmentFs::new(
                    inner,
                    &inode_alloc,
                    virtual_entries,
                )))
            }
            Some(cfg) => {
                let inner = PassthroughFs::new(cfg, inode_alloc.clone())?;
                FsServer::ReadWrite(Server::new(AugmentFs::new(
                    inner,
                    &inode_alloc,
                    virtual_entries,
                )))
            }
            None => FsServer::Null(Server::new(AugmentFs::new(
                NullFs,
                &inode_alloc,
                virtual_entries,
            ))),
        };
        Ok(Self {
            queues,
            queue_evts,
            interrupt,
            mem,
            allow_idmap,
            shm_region,
            server,
            stop_fd,
            exit_code,
            #[cfg(target_os = "macos")]
            map_sender,
        })
    }

    pub fn run(self) -> thread::JoinHandle<()> {
        thread::Builder::new()
            .name("fs worker".into())
            .spawn(|| self.work())
            .unwrap()
    }

    fn work(self) {
        // One thread per virtqueue: stock libkrun only polled queues 0/1 on a
        // single thread, serializing multi-queue guest readahead READs.
        let server = Arc::new(self.server);
        let exit_code = self.exit_code;
        let shm_region = self.shm_region;
        let allow_idmap = self.allow_idmap;
        #[cfg(target_os = "macos")]
        let map_sender = self.map_sender;

        let n = self.queues.len();
        let mut joins = Vec::with_capacity(n);
        let mut queues = self.queues;
        let mut queue_evts = self.queue_evts;

        for idx in 0..n {
            let queue = queues.remove(0);
            let queue_evt = queue_evts.remove(0);
            let stop_fd = self
                .stop_fd
                .try_clone()
                .expect("clone fs worker stop eventfd");
            let interrupt = self.interrupt.clone();
            let mem = self.mem.clone();
            let server = Arc::clone(&server);
            let exit_code = Arc::clone(&exit_code);
            let shm_region = shm_region.clone();
            #[cfg(target_os = "macos")]
            let map_sender = map_sender.clone();

            let handle = thread::Builder::new()
                .name(format!("fs-vq-{idx}"))
                .spawn(move || {
                    queue_loop(
                        idx,
                        queue,
                        queue_evt,
                        stop_fd,
                        interrupt,
                        mem,
                        server,
                        allow_idmap,
                        shm_region,
                        exit_code,
                        #[cfg(target_os = "macos")]
                        map_sender,
                    )
                })
                .unwrap();
            joins.push(handle);
        }

        for handle in joins {
            let _ = handle.join();
        }
    }
}

fn queue_loop(
    queue_index: usize,
    mut queue: Queue,
    queue_evt: Arc<EventFd>,
    stop_fd: EventFd,
    interrupt: InterruptTransport,
    mem: GuestMemoryMmap,
    server: Arc<FsServer>,
    allow_idmap: bool,
    shm_region: Option<VirtioShmRegion>,
    exit_code: Arc<AtomicI32>,
    #[cfg(target_os = "macos")] map_sender: Option<Sender<WorkerMessage>>,
) {
    const STOP_TAG: u64 = 1;
    const QUEUE_TAG: u64 = 2;

    let epoll = Epoll::new().unwrap();
    let _ = epoll.ctl(
        ControlOperation::Add,
        queue_evt.as_raw_fd(),
        &EpollEvent::new(EventSet::IN, QUEUE_TAG),
    );
    let _ = epoll.ctl(
        ControlOperation::Add,
        stop_fd.as_raw_fd(),
        &EpollEvent::new(EventSet::IN, STOP_TAG),
    );

    loop {
        let mut epoll_events = vec![EpollEvent::new(EventSet::empty(), 0); 8];
        match epoll.wait(epoll_events.len(), -1, epoll_events.as_mut_slice()) {
            Ok(ev_cnt) => {
                for event in &epoll_events[0..ev_cnt] {
                    let event_set = event.event_set();
                    let data = event.data();
                    if event_set != EventSet::IN {
                        log::warn!(
                            "fs-vq-{queue_index}: unknown event {event_set:?} data={data:?}"
                        );
                        continue;
                    }
                    if data == STOP_TAG {
                        debug!("fs-vq-{queue_index}: stopping");
                        let _ = stop_fd.read();
                        return;
                    }
                    if data == QUEUE_TAG {
                        handle_queue_event(
                            queue_index,
                            &mut queue,
                            &queue_evt,
                            &interrupt,
                            &mem,
                            &server,
                            allow_idmap,
                            &shm_region,
                            &exit_code,
                            #[cfg(target_os = "macos")]
                            &map_sender,
                        );
                    }
                }
            }
            Err(e) => {
                debug!("fs-vq-{queue_index}: epoll wait failed: {e}");
            }
        }
    }
}

fn handle_queue_event(
    queue_index: usize,
    queue: &mut Queue,
    queue_evt: &Arc<EventFd>,
    interrupt: &InterruptTransport,
    mem: &GuestMemoryMmap,
    server: &FsServer,
    allow_idmap: bool,
    shm_region: &Option<VirtioShmRegion>,
    exit_code: &Arc<AtomicI32>,
    #[cfg(target_os = "macos")] map_sender: &Option<Sender<WorkerMessage>>,
) {
    debug!("Fs: queue event: {queue_index}");
    if let Err(e) = queue_evt.read() {
        error!("Failed to get queue event: {e:?}");
    }

    loop {
        queue.disable_notification(mem).unwrap();
        process_queue(
            queue,
            interrupt,
            mem,
            server,
            allow_idmap,
            shm_region,
            exit_code,
            #[cfg(target_os = "macos")]
            map_sender,
        );
        if !queue.enable_notification(mem).unwrap() {
            break;
        }
    }
}

fn process_queue(
    queue: &mut Queue,
    interrupt: &InterruptTransport,
    mem: &GuestMemoryMmap,
    server: &FsServer,
    allow_idmap: bool,
    shm_region: &Option<VirtioShmRegion>,
    exit_code: &Arc<AtomicI32>,
    #[cfg(target_os = "macos")] map_sender: &Option<Sender<WorkerMessage>>,
) {
    while let Some(head) = queue.pop(mem) {
        let reader = Reader::new(mem, head.clone())
            .map_err(FsError::QueueReader)
            .unwrap();
        let writer = Writer::new(mem, head.clone())
            .map_err(FsError::QueueWriter)
            .unwrap();

        let len = match server.handle_message(
            reader,
            writer,
            allow_idmap,
            shm_region,
            exit_code,
            #[cfg(target_os = "macos")]
            map_sender,
        ) {
            Ok(len) => len,
            Err(e) => {
                error!("error handling message: {e:?}");
                0
            }
        };

        if let Err(e) = queue.add_used(mem, head.index, len as u32) {
            error!("failed to add used elements to the queue: {e:?}");
        }

        if queue.needs_notification(mem).unwrap() {
            interrupt.signal_used_queue();
        }
    }
}
