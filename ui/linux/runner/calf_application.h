#ifndef FLUTTER_CALF_APPLICATION_H_
#define FLUTTER_CALF_APPLICATION_H_

#include <gtk/gtk.h>

G_DECLARE_FINAL_TYPE(CalfApplication,
                     calf_application,
                     CALF,
                     APPLICATION,
                     GtkApplication)

/**
 * calf_application_new:
 *
 * Creates a new Flutter-based application.
 *
 * Returns: a new #CalfApplication.
 */
CalfApplication* calf_application_new();

#endif  // FLUTTER_CALF_APPLICATION_H_
