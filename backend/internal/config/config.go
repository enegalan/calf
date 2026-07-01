package config

const DefaultListenAddr = ":8080"

type Config struct {
	ListenAddr string
}

func Default() Config {
	return Config{
		ListenAddr: DefaultListenAddr,
	}
}

func Load() Config {
	return Default()
}
