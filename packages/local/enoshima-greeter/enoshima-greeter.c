#include <gio/gio.h>
#include <gio/gunixsocketaddress.h>
#include <gtk/gtk.h>
#include <json-glib/json-glib.h>
#include <locale.h>
#include <stdint.h>
#include <string.h>

typedef enum {
    PHASE_IDLE,
    PHASE_CREATE,
    PHASE_AUTH,
    PHASE_START,
    PHASE_CANCEL,
} AuthPhase;

typedef struct {
    GtkApplication *application;
    GtkWidget *window;
    GtkWidget *username;
    GtkWidget *identity;
    GtkWidget *other_user;
    GtkWidget *layout;
    GtkWidget *response_stack;
    GtkWidget *secret_response;
    GtkWidget *visible_response;
    GtkWidget *prompt;
    GtkWidget *message;
    GtkWidget *primary;
    GtkWidget *fingerprint;
    GtkWidget *clock;
    GtkWidget *date;
    GtkWidget *network;
    GtkWidget *battery;
    GtkWidget *caps_lock;
    GSocketConnection *connection;
    GNetworkMonitor *network_monitor;
    GListModel *monitors;
    GPtrArray *secondary_windows;
    GPtrArray *secondary_clocks;
    GPtrArray *secondary_statuses;
    gchar *default_user;
    gchar *pending_error;
    gchar *pending_power;
    guint power_reset_source;
    AuthPhase phase;
    gboolean awaiting_input;
    gboolean input_is_secret;
    gboolean busy;
    gboolean korean;
} Greeter;

typedef struct {
    Greeter *greeter;
    gchar *payload;
} IpcRequest;

static GtkWidget *label_with_class(const gchar *text,
                                   const gchar *css_class);

static const gchar *localized(Greeter *greeter, const gchar *key) {
    static const struct {
        const gchar *key;
        const gchar *en;
        const gchar *ko;
    } copy[] = {
        {"signing-in", "Signing in…", "로그인 중…"},
        {"sign-in", "Sign In", "로그인"},
        {"continue", "Continue", "계속"},
        {"auth-default", "Authenticate with password or fingerprint", "암호 또는 지문으로 인증"},
        {"auth-cancelled", "Authentication was cancelled. Try again.", "인증이 취소되었습니다. 다시 시도하세요."},
        {"auth-input", "Enter your authentication response.", "인증 정보를 입력하세요."},
        {"auth-failed", "Authentication failed. Try again.", "인증에 실패했습니다. 다시 시도하세요."},
        {"username-required", "Enter a user name.", "사용자 이름을 입력하세요."},
        {"fingerprint-ready", "Use fingerprint", "지문 사용"},
        {"fingerprint-progress", "Touch the fingerprint sensor…", "지문 센서를 터치하세요…"},
        {"caps-lock", "Caps Lock is on", "Caps Lock이 켜져 있습니다"},
        {"username", "User name", "사용자 이름"},
        {"password", "Password", "암호"},
        {"response", "Authentication response", "인증 응답"},
        {"other-user", "Other user", "다른 사용자"},
        {"managed-user", "Managed user", "관리 사용자"},
        {"mode", "ENOSHIMA // SIGN IN", "ENOSHIMA // 로그인"},
        {"network-check", "Checking network", "네트워크 확인 중"},
        {"offline", "○ Offline", "○ 오프라인"},
        {"connected", "● Connected", "● 연결됨"},
        {"power-check", "Checking power", "전원 상태 확인 중"},
        {"battery", "Battery", "배터리"},
        {"charging", "Charging", "충전 중"},
        {"restart", "Restart", "다시 시작"},
        {"shutdown", "Shut Down", "시스템 종료"},
        {"restart-confirm", "Select Restart again to confirm.", "다시 시작하려면 버튼을 한 번 더 누르세요."},
        {"shutdown-confirm", "Select Shut Down again to confirm.", "시스템을 종료하려면 버튼을 한 번 더 누르세요."},
        {"service-parse", "The authentication service returned an unreadable response.", "인증 서비스 응답을 해석하지 못했습니다."},
        {"service-format", "The authentication service returned an invalid response.", "인증 서비스 응답 형식이 올바르지 않습니다."},
        {"service-missing", "The authentication service socket is unavailable.", "인증 서비스 소켓을 사용할 수 없습니다."},
        {"sign-in-on", "Sign in on", "로그인 위치"},
        {NULL, NULL, NULL},
    };
    for (guint index = 0; copy[index].key != NULL; index++) {
        if (g_str_equal(copy[index].key, key))
            return greeter->korean ? copy[index].ko : copy[index].en;
    }
    return key;
}

static gchar *json_message(const gchar *type, const gchar *field,
                           const gchar *value, gboolean include_field) {
    JsonBuilder *builder = json_builder_new();
    JsonGenerator *generator = json_generator_new();
    JsonNode *root;
    gchar *data;

    json_builder_begin_object(builder);
    json_builder_set_member_name(builder, "type");
    json_builder_add_string_value(builder, type);
    if (include_field) {
        json_builder_set_member_name(builder, field);
        if (value != NULL)
            json_builder_add_string_value(builder, value);
        else
            json_builder_add_null_value(builder);
    }
    json_builder_end_object(builder);
    root = json_builder_get_root(builder);
    json_generator_set_root(generator, root);
    data = json_generator_to_data(generator, NULL);
    json_node_free(root);
    g_object_unref(generator);
    g_object_unref(builder);
    return data;
}

static gchar *json_start_session(void) {
    static const gchar *const command[] = {
        "uwsm", "start", "-e", "-D", "Hyprland", "start-hyprland", NULL};
    static const gchar *const environment[] = {
        "XDG_SESSION_TYPE=wayland",
        "XDG_SESSION_DESKTOP=enoshima",
        "XDG_CURRENT_DESKTOP=Hyprland",
        "GDK_BACKEND=wayland",
        "QT_QPA_PLATFORM=wayland",
        NULL};
    JsonBuilder *builder = json_builder_new();
    JsonGenerator *generator = json_generator_new();
    JsonNode *root;
    gchar *data;

    json_builder_begin_object(builder);
    json_builder_set_member_name(builder, "type");
    json_builder_add_string_value(builder, "start_session");
    json_builder_set_member_name(builder, "cmd");
    json_builder_begin_array(builder);
    for (guint index = 0; command[index] != NULL; index++)
        json_builder_add_string_value(builder, command[index]);
    json_builder_end_array(builder);
    json_builder_set_member_name(builder, "env");
    json_builder_begin_array(builder);
    for (guint index = 0; environment[index] != NULL; index++)
        json_builder_add_string_value(builder, environment[index]);
    json_builder_end_array(builder);
    json_builder_end_object(builder);

    root = json_builder_get_root(builder);
    json_generator_set_root(generator, root);
    data = json_generator_to_data(generator, NULL);
    json_node_free(root);
    g_object_unref(generator);
    g_object_unref(builder);
    return data;
}

static void set_message(Greeter *greeter, const gchar *text,
                        gboolean is_error) {
    gtk_label_set_text(GTK_LABEL(greeter->message), text != NULL ? text : "");
    if (is_error)
        gtk_widget_add_css_class(greeter->message, "error-message");
    else
        gtk_widget_remove_css_class(greeter->message, "error-message");
}

static void set_busy(Greeter *greeter, gboolean busy) {
    greeter->busy = busy;
    gtk_widget_set_sensitive(greeter->username, !busy && greeter->phase == PHASE_IDLE);
    gtk_widget_set_sensitive(greeter->other_user, !busy && greeter->phase == PHASE_IDLE);
    gtk_widget_set_sensitive(greeter->layout, !busy);
    gtk_widget_set_sensitive(greeter->secret_response,
                             !busy && greeter->awaiting_input);
    gtk_widget_set_sensitive(greeter->visible_response,
                             !busy && greeter->awaiting_input);
    gtk_widget_set_sensitive(greeter->primary, !busy);
    gtk_widget_set_sensitive(greeter->fingerprint,
                             !busy && greeter->awaiting_input &&
                                 greeter->input_is_secret);
    gtk_button_set_label(GTK_BUTTON(greeter->primary),
                         busy ? localized(greeter, "signing-in")
                              : (greeter->awaiting_input
                                     ? localized(greeter, "sign-in")
                                     : localized(greeter, "continue")));
}

static void reset_auth(Greeter *greeter, const gchar *message,
                       gboolean is_error) {
    greeter->phase = PHASE_IDLE;
    greeter->awaiting_input = FALSE;
    greeter->input_is_secret = TRUE;
    gtk_editable_set_text(GTK_EDITABLE(greeter->secret_response), "");
    gtk_editable_set_text(GTK_EDITABLE(greeter->visible_response), "");
    gtk_stack_set_visible_child_name(GTK_STACK(greeter->response_stack), "secret");
    gtk_label_set_text(GTK_LABEL(greeter->prompt), localized(greeter, "auth-default"));
    gtk_button_set_label(GTK_BUTTON(greeter->fingerprint), localized(greeter, "fingerprint-ready"));
    gtk_widget_remove_css_class(greeter->fingerprint, "fingerprint-progress");
    gtk_widget_remove_css_class(greeter->fingerprint, "fingerprint-failure");
    set_message(greeter, message, is_error);
    set_busy(greeter, FALSE);
    gtk_widget_grab_focus(gtk_widget_get_visible(greeter->username)
                              ? greeter->username
                              : greeter->primary);
}

static gboolean read_exact(GInputStream *stream, void *buffer, gsize length,
                           GError **error) {
    gsize bytes_read = 0;
    return g_input_stream_read_all(stream, buffer, length, &bytes_read, NULL,
                                   error) &&
           bytes_read == length;
}

static void ipc_request_free(IpcRequest *request) {
    g_free(request->payload);
    g_free(request);
}

static void ipc_worker(GTask *task, gpointer source_object,
                       gpointer task_data, GCancellable *cancellable) {
    (void)source_object;
    (void)cancellable;
    IpcRequest *request = task_data;
    GOutputStream *output = g_io_stream_get_output_stream(
        G_IO_STREAM(request->greeter->connection));
    GInputStream *input = g_io_stream_get_input_stream(
        G_IO_STREAM(request->greeter->connection));
    uint32_t request_length = (uint32_t)strlen(request->payload);
    uint32_t response_length = 0;
    gsize bytes_written = 0;
    GError *error = NULL;

    if (!g_output_stream_write_all(output, &request_length,
                                   sizeof(request_length), &bytes_written,
                                   NULL, &error) ||
        bytes_written != sizeof(request_length) ||
        !g_output_stream_write_all(output, request->payload, request_length,
                                   &bytes_written, NULL, &error) ||
        bytes_written != request_length ||
        !g_output_stream_flush(output, NULL, &error) ||
        !read_exact(input, &response_length, sizeof(response_length), &error)) {
        g_task_return_error(task, error != NULL
                                     ? error
                                     : g_error_new_literal(G_IO_ERROR,
                                                           G_IO_ERROR_FAILED,
                                                           "greetd IPC failed"));
        return;
    }

    if (response_length == 0 || response_length > 1024 * 1024) {
        g_task_return_new_error(task, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
                                "greetd returned an invalid payload length");
        return;
    }

    gchar *response = g_malloc0((gsize)response_length + 1);
    if (!read_exact(input, response, response_length, &error)) {
        g_free(response);
        g_task_return_error(task, error != NULL
                                     ? error
                                     : g_error_new_literal(G_IO_ERROR,
                                                           G_IO_ERROR_FAILED,
                                                           "greetd reply was truncated"));
        return;
    }
    g_task_return_pointer(task, response, g_free);
}

static void send_request(Greeter *greeter, gchar *payload, AuthPhase phase);

static void handle_response(Greeter *greeter, const gchar *response) {
    JsonParser *parser = json_parser_new();
    GError *error = NULL;
    if (!json_parser_load_from_data(parser, response, -1, &error)) {
        reset_auth(greeter, localized(greeter, "service-parse"), TRUE);
        g_clear_error(&error);
        g_object_unref(parser);
        return;
    }

    JsonNode *root = json_parser_get_root(parser);
    if (!JSON_NODE_HOLDS_OBJECT(root)) {
        reset_auth(greeter, localized(greeter, "service-format"), TRUE);
        g_object_unref(parser);
        return;
    }
    JsonObject *object = json_node_get_object(root);
    const gchar *type = json_object_get_string_member_with_default(
        object, "type", "error");

    if (g_str_equal(type, "success")) {
        if (greeter->phase == PHASE_START) {
            g_application_quit(G_APPLICATION(greeter->application));
        } else if (greeter->phase == PHASE_CANCEL) {
            gchar *message = g_steal_pointer(&greeter->pending_error);
            reset_auth(greeter,
                       message != NULL ? message
                                       : localized(greeter, "auth-cancelled"),
                       message != NULL);
            g_free(message);
        } else {
            send_request(greeter, json_start_session(), PHASE_START);
        }
        g_object_unref(parser);
        return;
    }

    if (g_str_equal(type, "auth_message")) {
        const gchar *auth_type = json_object_get_string_member_with_default(
            object, "auth_message_type", "error");
        const gchar *auth_message = json_object_get_string_member_with_default(
            object, "auth_message", localized(greeter, "auth-input"));
        if (g_str_equal(auth_type, "info") ||
            g_str_equal(auth_type, "error")) {
            set_message(greeter, auth_message,
                        g_str_equal(auth_type, "error"));
            send_request(greeter,
                         json_message("post_auth_message_response", "response",
                                      NULL, FALSE),
                         PHASE_AUTH);
        } else {
            greeter->awaiting_input = TRUE;
            greeter->input_is_secret = g_str_equal(auth_type, "secret");
            gtk_label_set_text(GTK_LABEL(greeter->prompt), auth_message);
            gtk_stack_set_visible_child_name(
                GTK_STACK(greeter->response_stack),
                greeter->input_is_secret ? "secret" : "visible");
            set_busy(greeter, FALSE);
            gtk_widget_grab_focus(greeter->input_is_secret
                                      ? greeter->secret_response
                                      : greeter->visible_response);
        }
        g_object_unref(parser);
        return;
    }

    const gchar *description = json_object_get_string_member_with_default(
        object, "description", localized(greeter, "auth-failed"));
    gtk_widget_add_css_class(greeter->fingerprint, "fingerprint-failure");
    if (greeter->phase == PHASE_CANCEL) {
        reset_auth(greeter, description, TRUE);
        g_object_unref(parser);
        return;
    }
    g_free(greeter->pending_error);
    greeter->pending_error = g_strdup(description);
    send_request(greeter,
                 json_message("cancel_session", NULL, NULL, FALSE),
                 PHASE_CANCEL);
    g_object_unref(parser);
}

static void ipc_complete(GObject *source_object, GAsyncResult *result,
                         gpointer user_data) {
    (void)source_object;
    Greeter *greeter = user_data;
    GError *error = NULL;
    gchar *response = g_task_propagate_pointer(G_TASK(result), &error);
    if (response == NULL) {
        reset_auth(greeter, error != NULL ? error->message
                                          : localized(greeter, "auth-failed"),
                   TRUE);
        g_clear_error(&error);
        return;
    }
    handle_response(greeter, response);
    g_free(response);
}

static void send_request(Greeter *greeter, gchar *payload, AuthPhase phase) {
    IpcRequest *request = g_new0(IpcRequest, 1);
    request->greeter = greeter;
    request->payload = payload;
    greeter->phase = phase;
    set_busy(greeter, TRUE);
    GTask *task = g_task_new(NULL, NULL, ipc_complete, greeter);
    g_task_set_task_data(task, request, (GDestroyNotify)ipc_request_free);
    g_task_run_in_thread(task, ipc_worker);
    g_object_unref(task);
}

static void submit_response(Greeter *greeter, const gchar *response) {
    greeter->awaiting_input = FALSE;
    send_request(greeter,
                 json_message("post_auth_message_response", "response",
                              response, TRUE),
                 PHASE_AUTH);
}

static void primary_clicked(GtkButton *button, gpointer user_data) {
    (void)button;
    Greeter *greeter = user_data;
    if (greeter->busy)
        return;
    if (greeter->awaiting_input) {
        GtkWidget *entry = greeter->input_is_secret
                               ? greeter->secret_response
                               : greeter->visible_response;
        gchar *response = g_strdup(gtk_editable_get_text(GTK_EDITABLE(entry)));
        submit_response(greeter, response);
        g_free(response);
        return;
    }

    const gchar *username = gtk_editable_get_text(GTK_EDITABLE(greeter->username));
    if (username == NULL || *username == '\0') {
        set_message(greeter, localized(greeter, "username-required"), TRUE);
        return;
    }
    set_message(greeter, "", FALSE);
    send_request(greeter,
                 json_message("create_session", "username", username, TRUE),
                 PHASE_CREATE);
}

static void fingerprint_clicked(GtkButton *button, gpointer user_data) {
    (void)button;
    Greeter *greeter = user_data;
    if (greeter->busy || !greeter->awaiting_input ||
        !greeter->input_is_secret)
        return;
    gtk_button_set_label(GTK_BUTTON(greeter->fingerprint), localized(greeter, "fingerprint-progress"));
    gtk_widget_add_css_class(greeter->fingerprint, "fingerprint-progress");
    set_message(greeter, localized(greeter, "fingerprint-progress"), FALSE);
    submit_response(greeter, "");
}

static void entry_activated(GtkWidget *entry, gpointer user_data) {
    (void)entry;
    primary_clicked(NULL, user_data);
}

static gboolean reset_power_confirmation(gpointer user_data) {
    Greeter *greeter = user_data;
    g_clear_pointer(&greeter->pending_power, g_free);
    greeter->power_reset_source = 0;
    set_message(greeter, "", FALSE);
    return G_SOURCE_REMOVE;
}

static void power_clicked(GtkButton *button, gpointer user_data) {
    Greeter *greeter = user_data;
    const gchar *action = g_object_get_data(G_OBJECT(button), "power-action");
    if (greeter->pending_power == NULL ||
        !g_str_equal(greeter->pending_power, action)) {
        g_free(greeter->pending_power);
        greeter->pending_power = g_strdup(action);
        set_message(greeter,
                    g_str_equal(action, "Reboot")
                        ? localized(greeter, "restart-confirm")
                        : localized(greeter, "shutdown-confirm"),
                    FALSE);
        if (greeter->power_reset_source != 0)
            g_source_remove(greeter->power_reset_source);
        greeter->power_reset_source =
            g_timeout_add_seconds(5, reset_power_confirmation, greeter);
        return;
    }

    GError *error = NULL;
    GDBusConnection *bus = g_bus_get_sync(G_BUS_TYPE_SYSTEM, NULL, &error);
    if (bus == NULL) {
        set_message(greeter, error->message, TRUE);
        g_clear_error(&error);
        return;
    }
    GVariant *reply = g_dbus_connection_call_sync(
        bus, "org.freedesktop.login1", "/org/freedesktop/login1",
        "org.freedesktop.login1.Manager", action, g_variant_new("(b)", TRUE),
        NULL, G_DBUS_CALL_FLAGS_NONE, 10000, NULL, &error);
    if (reply != NULL)
        g_variant_unref(reply);
    else {
        set_message(greeter, error->message, TRUE);
        g_clear_error(&error);
    }
    g_object_unref(bus);
}

static gboolean update_clock(gpointer user_data) {
    Greeter *greeter = user_data;
    GDateTime *now = g_date_time_new_now_local();
    gchar *time = g_date_time_format(now, "%H:%M");
    gchar *date = g_date_time_format(
        now, greeter->korean ? "%Y년 %-m월 %-d일 %A" : "%A, %B %-d, %Y");
    gtk_label_set_text(GTK_LABEL(greeter->clock), time);
    gtk_label_set_text(GTK_LABEL(greeter->date), date);
    if (greeter->secondary_clocks != NULL) {
        for (guint index = 0; index < greeter->secondary_clocks->len; index++)
            gtk_label_set_text(
                GTK_LABEL(g_ptr_array_index(greeter->secondary_clocks, index)),
                time);
    }
    g_free(time);
    g_free(date);
    g_date_time_unref(now);
    return G_SOURCE_CONTINUE;
}

static void update_secondary_status(Greeter *greeter) {
    if (greeter->secondary_statuses == NULL || greeter->network == NULL ||
        greeter->battery == NULL)
        return;
    gchar *summary = g_strdup_printf(
        "%s  ·  %s", gtk_label_get_text(GTK_LABEL(greeter->network)),
        gtk_label_get_text(GTK_LABEL(greeter->battery)));
    for (guint index = 0; index < greeter->secondary_statuses->len; index++)
        gtk_label_set_text(
            GTK_LABEL(g_ptr_array_index(greeter->secondary_statuses, index)),
            summary);
    g_free(summary);
}

static gchar *dbus_string_property(GDBusConnection *bus,
                                   const gchar *destination,
                                   const gchar *path,
                                   const gchar *interface,
                                   const gchar *property) {
    GError *error = NULL;
    GVariant *reply = g_dbus_connection_call_sync(
        bus, destination, path, "org.freedesktop.DBus.Properties", "Get",
        g_variant_new("(ss)", interface, property), G_VARIANT_TYPE("(v)"),
        G_DBUS_CALL_FLAGS_NONE, 1200, NULL, &error);
    if (reply == NULL) {
        g_clear_error(&error);
        return NULL;
    }

    GVariant *boxed = NULL;
    g_variant_get(reply, "(@v)", &boxed);
    GVariant *value = g_variant_get_variant(boxed);
    gchar *result = NULL;
    if (g_variant_is_of_type(value, G_VARIANT_TYPE_STRING) ||
        g_variant_is_of_type(value, G_VARIANT_TYPE_OBJECT_PATH))
        result = g_variant_dup_string(value, NULL);
    g_variant_unref(value);
    g_variant_unref(boxed);
    g_variant_unref(reply);
    return result;
}

static gchar *network_connection_name(void) {
    GError *error = NULL;
    GDBusConnection *bus = g_bus_get_sync(G_BUS_TYPE_SYSTEM, NULL, &error);
    if (bus == NULL) {
        g_clear_error(&error);
        return NULL;
    }
    gchar *primary = dbus_string_property(
        bus, "org.freedesktop.NetworkManager", "/org/freedesktop/NetworkManager",
        "org.freedesktop.NetworkManager", "PrimaryConnection");
    gchar *name = NULL;
    if (primary != NULL && !g_str_equal(primary, "/"))
        name = dbus_string_property(
            bus, "org.freedesktop.NetworkManager", primary,
            "org.freedesktop.NetworkManager.Connection.Active", "Id");
    g_free(primary);
    g_object_unref(bus);
    return name;
}

static void update_network(GNetworkMonitor *monitor, gboolean available,
                           gpointer user_data) {
    (void)monitor;
    Greeter *greeter = user_data;
    gchar *connection = available ? network_connection_name() : NULL;
    gchar *label = connection != NULL
                       ? g_strdup_printf("● %s", connection)
                       : g_strdup(localized(
                             greeter, available ? "connected" : "offline"));
    gtk_label_set_text(GTK_LABEL(greeter->network), label);
    g_free(label);
    g_free(connection);
    update_secondary_status(greeter);
}

static void update_battery(Greeter *greeter) {
    GDir *directory = g_dir_open("/sys/class/power_supply", 0, NULL);
    const gchar *entry = NULL;
    gchar *capacity_path = NULL;
    gchar *status_path = NULL;
    while (directory != NULL && (entry = g_dir_read_name(directory)) != NULL) {
        if (!g_str_has_prefix(entry, "BAT"))
            continue;
        capacity_path = g_build_filename("/sys/class/power_supply", entry,
                                         "capacity", NULL);
        status_path = g_build_filename("/sys/class/power_supply", entry,
                                       "status", NULL);
        break;
    }
    if (directory != NULL)
        g_dir_close(directory);

    gchar *capacity = NULL;
    gchar *status = NULL;
    if (capacity_path != NULL &&
        g_file_get_contents(capacity_path, &capacity, NULL, NULL)) {
        g_strchomp(capacity);
        if (status_path != NULL)
            g_file_get_contents(status_path, &status, NULL, NULL);
        if (status != NULL)
            g_strchomp(status);
        const gboolean charging =
            status != NULL && (g_str_equal(status, "Charging") ||
                               g_str_equal(status, "Full"));
        gchar *label = g_strdup_printf(
            "%s %s%%", localized(greeter, charging ? "charging" : "battery"),
            capacity);
        gtk_label_set_text(GTK_LABEL(greeter->battery), label);
        g_free(label);
        g_free(capacity);
    } else {
        gtk_label_set_text(GTK_LABEL(greeter->battery),
                           localized(greeter, "power-check"));
    }
    g_free(status);
    g_free(capacity_path);
    g_free(status_path);
    update_secondary_status(greeter);
}

static void other_user_clicked(GtkButton *button, gpointer user_data) {
    (void)button;
    Greeter *greeter = user_data;
    if (greeter->busy || greeter->phase != PHASE_IDLE)
        return;
    gboolean reveal = !gtk_widget_get_visible(greeter->username);
    gtk_widget_set_visible(greeter->username, reveal);
    gtk_widget_set_visible(greeter->identity, !reveal);
    gtk_button_set_label(GTK_BUTTON(greeter->other_user),
                         reveal ? greeter->default_user
                                : localized(greeter, "other-user"));
    if (!reveal)
        gtk_editable_set_text(GTK_EDITABLE(greeter->username),
                              greeter->default_user);
    gtk_widget_grab_focus(reveal ? greeter->username : greeter->primary);
}

static void layout_changed(GObject *object, GParamSpec *parameter,
                           gpointer user_data) {
    (void)parameter;
    (void)user_data;
    guint selected = gtk_drop_down_get_selected(GTK_DROP_DOWN(object));
    GError *error = NULL;
    GSubprocess *process = g_subprocess_new(
        G_SUBPROCESS_FLAGS_STDOUT_SILENCE | G_SUBPROCESS_FLAGS_STDERR_SILENCE,
        &error, "hyprctl", "keyword", "input:kb_layout",
        selected == 1 ? "kr" : "us", NULL);
    if (process != NULL)
        g_object_unref(process);
    g_clear_error(&error);
}

static GtkWidget *icon_button(const gchar *label, const gchar *icon_name) {
    GtkWidget *button = gtk_button_new();
    GtkWidget *content = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    GtkWidget *icon = gtk_image_new_from_icon_name(icon_name);
    GtkWidget *text = gtk_label_new(label);
    gtk_box_append(GTK_BOX(content), icon);
    gtk_box_append(GTK_BOX(content), text);
    gtk_button_set_child(GTK_BUTTON(button), content);
    return button;
}

static GdkMonitor *primary_monitor(GListModel *monitors) {
    const gchar *wanted = g_getenv("ENOSHIMA_AUTH_PRIMARY_OUTPUT");
    if (wanted == NULL || *wanted == '\0')
        wanted = "eDP-1";
    for (guint index = 0; index < g_list_model_get_n_items(monitors); index++) {
        GdkMonitor *monitor = g_list_model_get_item(monitors, index);
        const gchar *connector = gdk_monitor_get_connector(monitor);
        if (connector != NULL && g_str_equal(connector, wanted))
            return monitor;
        g_object_unref(monitor);
    }
    return g_list_model_get_n_items(monitors) > 0
               ? g_list_model_get_item(monitors, 0)
               : NULL;
}

static void fullscreen_on_primary(GtkWindow *window, GListModel *monitors) {
    GdkMonitor *monitor = primary_monitor(monitors);
    if (monitor != NULL) {
        gtk_window_fullscreen_on_monitor(window, monitor);
        g_object_unref(monitor);
    } else {
        gtk_window_fullscreen(window);
    }
}

static void rebuild_secondary_windows(Greeter *greeter) {
    g_ptr_array_set_size(greeter->secondary_clocks, 0);
    g_ptr_array_set_size(greeter->secondary_statuses, 0);
    g_ptr_array_set_size(greeter->secondary_windows, 0);

    GdkMonitor *primary = primary_monitor(greeter->monitors);
    for (guint index = 0; index < g_list_model_get_n_items(greeter->monitors);
         index++) {
        GdkMonitor *monitor = g_list_model_get_item(greeter->monitors, index);
        if (monitor == primary) {
            g_object_unref(monitor);
            continue;
        }

        GtkWidget *window = gtk_application_window_new(greeter->application);
        gtk_window_set_title(GTK_WINDOW(window), "Enoshima Auth Status");
        gtk_window_set_decorated(GTK_WINDOW(window), FALSE);
        gtk_widget_add_css_class(window, "auth-window");
        GtkWidget *overlay = gtk_overlay_new();
        GtkWidget *picture = gtk_picture_new_for_filename(
            "/etc/greetd/background-16x10.jpg");
        gtk_picture_set_content_fit(GTK_PICTURE(picture), GTK_CONTENT_FIT_COVER);
        gtk_widget_set_hexpand(picture, TRUE);
        gtk_widget_set_vexpand(picture, TRUE);
        gtk_overlay_set_child(GTK_OVERLAY(overlay), picture);
        GtkWidget *scrim = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
        gtk_widget_set_hexpand(scrim, TRUE);
        gtk_widget_set_vexpand(scrim, TRUE);
        gtk_widget_add_css_class(scrim, "auth-scrim");
        gtk_overlay_add_overlay(GTK_OVERLAY(overlay), scrim);

        GtkWidget *status = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);
        gtk_widget_set_halign(status, GTK_ALIGN_CENTER);
        gtk_widget_set_valign(status, GTK_ALIGN_CENTER);
        gtk_widget_add_css_class(status, "secondary-status-card");
        GtkWidget *clock = label_with_class(
            gtk_label_get_text(GTK_LABEL(greeter->clock)), "auth-clock");
        const gchar *connector = gdk_monitor_get_connector(primary);
        gchar *direction = g_strdup_printf(
            "%s %s", localized(greeter, "sign-in-on"),
            connector != NULL ? connector : "primary display");
        GtkWidget *owner = label_with_class(direction, "auth-mode");
        GtkWidget *summary = label_with_class("", "status-label");
        g_free(direction);
        gtk_box_append(GTK_BOX(status), clock);
        gtk_box_append(GTK_BOX(status), owner);
        gtk_box_append(GTK_BOX(status), summary);
        gtk_overlay_add_overlay(GTK_OVERLAY(overlay), status);
        gtk_window_set_child(GTK_WINDOW(window), overlay);
        gtk_window_fullscreen_on_monitor(GTK_WINDOW(window), monitor);
        gtk_window_present(GTK_WINDOW(window));
        g_ptr_array_add(greeter->secondary_windows, window);
        g_ptr_array_add(greeter->secondary_clocks, clock);
        g_ptr_array_add(greeter->secondary_statuses, summary);
        g_object_unref(monitor);
    }
    if (primary != NULL)
        g_object_unref(primary);
    update_secondary_status(greeter);
}

static void monitors_changed(GListModel *model, guint position, guint removed,
                             guint added, gpointer user_data) {
    (void)model;
    (void)position;
    (void)removed;
    (void)added;
    Greeter *greeter = user_data;
    fullscreen_on_primary(GTK_WINDOW(greeter->window), greeter->monitors);
    rebuild_secondary_windows(greeter);
}

static gboolean key_pressed(GtkEventControllerKey *controller, guint keyval,
                            guint keycode, GdkModifierType state,
                            gpointer user_data) {
    (void)controller;
    (void)keyval;
    (void)keycode;
    Greeter *greeter = user_data;
    gtk_widget_set_visible(greeter->caps_lock, (state & GDK_LOCK_MASK) != 0);
    return FALSE;
}

static GtkWidget *label_with_class(const gchar *text, const gchar *css_class) {
    GtkWidget *label = gtk_label_new(text);
    gtk_widget_add_css_class(label, css_class);
    return label;
}

static void load_css(void) {
    GtkCssProvider *provider = gtk_css_provider_new();
    gtk_css_provider_load_from_path(provider,
                                    "/etc/greetd/enoshima-greeter.css");
    gtk_style_context_add_provider_for_display(
        gdk_display_get_default(), GTK_STYLE_PROVIDER(provider),
        GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(provider);
}

static void connect_greetd(Greeter *greeter) {
    const gchar *socket_path = g_getenv("GREETD_SOCK");
    if (socket_path == NULL || *socket_path == '\0') {
        set_message(greeter, localized(greeter, "service-missing"), TRUE);
        set_busy(greeter, TRUE);
        return;
    }
    GSocketClient *client = g_socket_client_new();
    GSocketAddress *address = g_unix_socket_address_new(socket_path);
    GError *error = NULL;
    greeter->connection =
        g_socket_client_connect(client, G_SOCKET_CONNECTABLE(address), NULL,
                                &error);
    g_object_unref(address);
    g_object_unref(client);
    if (greeter->connection == NULL) {
        set_message(greeter, error->message, TRUE);
        set_busy(greeter, TRUE);
        g_clear_error(&error);
    }
}

static void activate(GtkApplication *application, gpointer user_data) {
    Greeter *greeter = user_data;
    greeter->application = application;
    load_css();
    greeter->monitors = g_object_ref(
        gdk_display_get_monitors(gdk_display_get_default()));
    greeter->secondary_windows =
        g_ptr_array_new_with_free_func((GDestroyNotify)gtk_window_destroy);
    greeter->secondary_clocks = g_ptr_array_new();
    greeter->secondary_statuses = g_ptr_array_new();

    greeter->window = gtk_application_window_new(application);
    gtk_window_set_title(GTK_WINDOW(greeter->window), "Enoshima Auth");
    gtk_window_set_decorated(GTK_WINDOW(greeter->window), FALSE);
    gtk_window_set_default_size(GTK_WINDOW(greeter->window), 1280, 800);
    fullscreen_on_primary(GTK_WINDOW(greeter->window), greeter->monitors);
    gtk_widget_add_css_class(greeter->window, "auth-window");

    GtkWidget *overlay = gtk_overlay_new();
    GtkWidget *picture = gtk_picture_new_for_filename(
        "/etc/greetd/background-16x10.jpg");
    gtk_picture_set_content_fit(GTK_PICTURE(picture), GTK_CONTENT_FIT_COVER);
    gtk_widget_set_hexpand(picture, TRUE);
    gtk_widget_set_vexpand(picture, TRUE);
    gtk_overlay_set_child(GTK_OVERLAY(overlay), picture);

    GtkWidget *scrim = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_hexpand(scrim, TRUE);
    gtk_widget_set_vexpand(scrim, TRUE);
    gtk_widget_add_css_class(scrim, "auth-scrim");
    gtk_overlay_add_overlay(GTK_OVERLAY(overlay), scrim);

    GtkWidget *card = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
    gtk_widget_set_halign(card, GTK_ALIGN_CENTER);
    gtk_widget_set_valign(card, GTK_ALIGN_CENTER);
    gtk_widget_set_size_request(card, 420, -1);
    gtk_widget_add_css_class(card, "auth-card");
    gtk_overlay_add_overlay(GTK_OVERLAY(overlay), card);

    GtkWidget *status = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    gtk_widget_add_css_class(status, "status-row");
    greeter->network =
        label_with_class(localized(greeter, "network-check"), "status-label");
    const gchar *layouts[] = {"English (US)", "한국어 (Korean)", NULL};
    greeter->layout = gtk_drop_down_new_from_strings(layouts);
    gtk_drop_down_set_selected(GTK_DROP_DOWN(greeter->layout),
                               greeter->korean ? 1 : 0);
    gtk_widget_add_css_class(greeter->layout, "layout-selector");
    gtk_accessible_update_property(
        GTK_ACCESSIBLE(greeter->layout), GTK_ACCESSIBLE_PROPERTY_LABEL,
        greeter->korean ? "키보드 레이아웃" : "Keyboard layout", -1);
    gtk_widget_set_hexpand(greeter->layout, TRUE);
    gtk_widget_set_halign(greeter->layout, GTK_ALIGN_CENTER);
    greeter->battery =
        label_with_class(localized(greeter, "power-check"), "status-label");
    gtk_box_append(GTK_BOX(status), greeter->network);
    gtk_box_append(GTK_BOX(status), greeter->layout);
    gtk_box_append(GTK_BOX(status), greeter->battery);
    gtk_box_append(GTK_BOX(card), status);

    greeter->clock = label_with_class("00:00", "auth-clock");
    greeter->date = label_with_class("", "auth-date");
    gtk_box_append(GTK_BOX(card), greeter->clock);
    gtk_box_append(GTK_BOX(card), greeter->date);

    GtkWidget *mode = label_with_class(localized(greeter, "mode"), "auth-mode");
    gtk_box_append(GTK_BOX(card), mode);

    GtkWidget *user_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    greeter->identity = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    gtk_widget_set_hexpand(greeter->identity, TRUE);
    gtk_widget_add_css_class(greeter->identity, "identity-card");
    GtkWidget *avatar = gtk_image_new_from_icon_name("avatar-default-symbolic");
    gtk_image_set_pixel_size(GTK_IMAGE(avatar), 40);
    GtkWidget *identity_copy = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    gtk_widget_set_hexpand(identity_copy, TRUE);
    GtkWidget *identity_name =
        label_with_class(greeter->default_user, "identity-name");
    GtkWidget *identity_kind = label_with_class(
        localized(greeter, "managed-user"), "identity-kind");
    gtk_widget_set_halign(identity_name, GTK_ALIGN_START);
    gtk_widget_set_halign(identity_kind, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(identity_copy), identity_name);
    gtk_box_append(GTK_BOX(identity_copy), identity_kind);
    gtk_box_append(GTK_BOX(greeter->identity), avatar);
    gtk_box_append(GTK_BOX(greeter->identity), identity_copy);
    greeter->other_user =
        gtk_button_new_with_label(localized(greeter, "other-user"));
    gtk_widget_add_css_class(greeter->other_user, "other-user-action");
    gtk_box_append(GTK_BOX(user_row), greeter->identity);
    gtk_box_append(GTK_BOX(user_row), greeter->other_user);
    gtk_box_append(GTK_BOX(card), user_row);

    greeter->username = gtk_entry_new();
    gtk_entry_set_placeholder_text(GTK_ENTRY(greeter->username),
                                   localized(greeter, "username"));
    gtk_editable_set_text(GTK_EDITABLE(greeter->username),
                          greeter->default_user);
    gtk_widget_add_css_class(greeter->username, "auth-entry");
    gtk_widget_set_visible(greeter->username, FALSE);
    gtk_box_append(GTK_BOX(card), greeter->username);

    greeter->prompt =
        label_with_class(localized(greeter, "auth-default"), "auth-prompt");
    gtk_widget_set_halign(greeter->prompt, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(card), greeter->prompt);

    greeter->response_stack = gtk_stack_new();
    greeter->secret_response = gtk_password_entry_new();
    gtk_password_entry_set_show_peek_icon(
        GTK_PASSWORD_ENTRY(greeter->secret_response), TRUE);
    g_object_set(greeter->secret_response, "placeholder-text",
                 localized(greeter, "password"), NULL);
    gtk_widget_add_css_class(greeter->secret_response, "auth-entry");
    greeter->visible_response = gtk_entry_new();
    gtk_entry_set_placeholder_text(GTK_ENTRY(greeter->visible_response),
                                   localized(greeter, "response"));
    gtk_widget_add_css_class(greeter->visible_response, "auth-entry");
    gtk_stack_add_named(GTK_STACK(greeter->response_stack),
                        greeter->secret_response, "secret");
    gtk_stack_add_named(GTK_STACK(greeter->response_stack),
                        greeter->visible_response, "visible");
    gtk_widget_set_sensitive(greeter->secret_response, FALSE);
    gtk_widget_set_sensitive(greeter->visible_response, FALSE);
    gtk_box_append(GTK_BOX(card), greeter->response_stack);

    greeter->caps_lock = label_with_class(localized(greeter, "caps-lock"),
                                          "warning-message");
    gtk_widget_set_visible(greeter->caps_lock, FALSE);
    gtk_box_append(GTK_BOX(card), greeter->caps_lock);

    greeter->fingerprint =
        gtk_button_new_with_label(localized(greeter, "fingerprint-ready"));
    gtk_widget_add_css_class(greeter->fingerprint, "fingerprint-button");
    gtk_widget_set_sensitive(greeter->fingerprint, FALSE);
    gtk_box_append(GTK_BOX(card), greeter->fingerprint);

    greeter->message = label_with_class("", "auth-message");
    gtk_label_set_wrap(GTK_LABEL(greeter->message), TRUE);
    gtk_box_append(GTK_BOX(card), greeter->message);

    greeter->primary =
        gtk_button_new_with_label(localized(greeter, "continue"));
    gtk_widget_add_css_class(greeter->primary, "primary-action");
    gtk_box_append(GTK_BOX(card), greeter->primary);

    GtkWidget *power_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
    gtk_widget_set_halign(power_row, GTK_ALIGN_CENTER);
    GtkWidget *reboot = icon_button(localized(greeter, "restart"),
                                    "system-reboot-symbolic");
    GtkWidget *poweroff = icon_button(localized(greeter, "shutdown"),
                                      "system-shutdown-symbolic");
    gtk_widget_add_css_class(reboot, "secondary-action");
    gtk_widget_add_css_class(poweroff, "secondary-action");
    g_object_set_data(G_OBJECT(reboot), "power-action", "Reboot");
    g_object_set_data(G_OBJECT(poweroff), "power-action", "PowerOff");
    gtk_box_append(GTK_BOX(power_row), reboot);
    gtk_box_append(GTK_BOX(power_row), poweroff);
    gtk_box_append(GTK_BOX(card), power_row);

    g_signal_connect(greeter->primary, "clicked", G_CALLBACK(primary_clicked),
                     greeter);
    g_signal_connect(greeter->fingerprint, "clicked",
                     G_CALLBACK(fingerprint_clicked), greeter);
    g_signal_connect(greeter->username, "activate", G_CALLBACK(entry_activated),
                     greeter);
    g_signal_connect(greeter->other_user, "clicked",
                     G_CALLBACK(other_user_clicked), greeter);
    g_signal_connect(greeter->layout, "notify::selected",
                     G_CALLBACK(layout_changed), greeter);
    g_signal_connect(greeter->secret_response, "activate",
                     G_CALLBACK(entry_activated), greeter);
    g_signal_connect(greeter->visible_response, "activate",
                     G_CALLBACK(entry_activated), greeter);
    g_signal_connect(reboot, "clicked", G_CALLBACK(power_clicked), greeter);
    g_signal_connect(poweroff, "clicked", G_CALLBACK(power_clicked), greeter);

    GtkEventController *keys = gtk_event_controller_key_new();
    g_signal_connect(keys, "key-pressed", G_CALLBACK(key_pressed), greeter);
    gtk_widget_add_controller(greeter->window, keys);

    greeter->network_monitor = g_network_monitor_get_default();
    g_object_ref(greeter->network_monitor);
    update_network(greeter->network_monitor,
                   g_network_monitor_get_network_available(
                       greeter->network_monitor),
                   greeter);
    g_signal_connect(greeter->network_monitor, "network-changed",
                     G_CALLBACK(update_network), greeter);
    update_battery(greeter);
    update_clock(greeter);
    g_timeout_add_seconds(1, update_clock, greeter);

    gtk_window_set_child(GTK_WINDOW(greeter->window), overlay);
    gtk_window_present(GTK_WINDOW(greeter->window));
    rebuild_secondary_windows(greeter);
    g_signal_connect(greeter->monitors, "items-changed",
                     G_CALLBACK(monitors_changed), greeter);
    connect_greetd(greeter);
    gtk_widget_grab_focus(greeter->primary);
}

static gboolean self_test(void) {
    gchar *create = json_message("create_session", "username", "test", TRUE);
    gchar *post = json_message("post_auth_message_response", "response", "pw",
                               TRUE);
    gchar *start = json_start_session();
    gboolean valid = strstr(create, "create_session") != NULL &&
                     strstr(create, "test") != NULL &&
                     strstr(post, "post_auth_message_response") != NULL &&
                     strstr(start, "start_session") != NULL &&
                     strstr(start, "start-hyprland") != NULL;
    g_free(create);
    g_free(post);
    g_free(start);
    if (valid)
        g_print("enoshima-greeter self-test passed\n");
    return valid;
}

int main(int argc, char **argv) {
    Greeter greeter = {0};
    const gchar *locale = setlocale(LC_ALL, "");
    greeter.korean = locale != NULL && g_str_has_prefix(locale, "ko");
    greeter.default_user = g_strdup(g_get_user_name());
    greeter.input_is_secret = TRUE;

    for (int index = 1; index < argc; index++) {
        if (g_str_equal(argv[index], "--self-test")) {
            g_free(greeter.default_user);
            return self_test() ? 0 : 1;
        }
        if (g_str_equal(argv[index], "--user") && index + 1 < argc) {
            g_free(greeter.default_user);
            greeter.default_user = g_strdup(argv[++index]);
        }
    }

    GtkApplication *application = gtk_application_new(
        "org.enoshima.Greeter", G_APPLICATION_NON_UNIQUE);
    g_signal_connect(application, "activate", G_CALLBACK(activate), &greeter);
    int status = g_application_run(G_APPLICATION(application), 1, argv);

    if (greeter.power_reset_source != 0)
        g_source_remove(greeter.power_reset_source);
    g_clear_object(&greeter.connection);
    g_clear_object(&greeter.network_monitor);
    if (greeter.secondary_clocks != NULL)
        g_ptr_array_unref(greeter.secondary_clocks);
    if (greeter.secondary_statuses != NULL)
        g_ptr_array_unref(greeter.secondary_statuses);
    if (greeter.secondary_windows != NULL)
        g_ptr_array_unref(greeter.secondary_windows);
    g_clear_object(&greeter.monitors);
    g_clear_pointer(&greeter.default_user, g_free);
    g_clear_pointer(&greeter.pending_error, g_free);
    g_clear_pointer(&greeter.pending_power, g_free);
    g_object_unref(application);
    return status;
}
