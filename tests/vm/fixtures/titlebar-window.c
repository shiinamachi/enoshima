#include <gtk/gtk.h>

static void activate(GtkApplication *application, gpointer user_data) {
    (void)user_data;
    GtkWidget *window = gtk_application_window_new(application);
    gtk_window_set_title(GTK_WINDOW(window), "Enoshima Titlebar Fixture");
    gtk_window_set_decorated(GTK_WINDOW(window), FALSE);
    gtk_window_set_default_size(GTK_WINDOW(window), 900, 560);

    GtkWidget *content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
    gtk_widget_set_halign(content, GTK_ALIGN_CENTER);
    gtk_widget_set_valign(content, GTK_ALIGN_CENTER);
    GtkWidget *heading = gtk_label_new("Enoshima system titlebar");
    GtkWidget *body = gtk_label_new(
        "This undecorated Wayland client exercises compositor-owned controls.");
    gtk_widget_add_css_class(heading, "title-1");
    gtk_widget_add_css_class(body, "dim-label");
    gtk_box_append(GTK_BOX(content), heading);
    gtk_box_append(GTK_BOX(content), body);
    gtk_window_set_child(GTK_WINDOW(window), content);
    gtk_window_present(GTK_WINDOW(window));
}

int main(void) {
    GtkApplication *application = gtk_application_new(
        "org.enoshima.TitlebarFixture", G_APPLICATION_NON_UNIQUE);
    g_signal_connect(application, "activate", G_CALLBACK(activate), NULL);
    int status = g_application_run(G_APPLICATION(application), 0, NULL);
    g_object_unref(application);
    return status;
}
