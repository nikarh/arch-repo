#define _GNU_SOURCE

#include <dbus/dbus.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define LOGIND_SERVICE "org.freedesktop.login1"
#define LOGIND_PATH "/org/freedesktop/login1"
#define LOGIND_MANAGER_INTERFACE "org.freedesktop.login1.Manager"
#define LOGIND_SESSION_INTERFACE "org.freedesktop.login1.Session"

char *get_session_id(DBusConnection *conn) {
  dbus_uint32_t pid = getpid();

  DBusMessage *message = dbus_message_new_method_call(
      LOGIND_SERVICE, LOGIND_PATH, LOGIND_MANAGER_INTERFACE, "GetSessionByPID");

  if (message == NULL) {
    fprintf(stderr, "Couldn't allocate dbus message\n");
    exit(1);
  }

  if (!dbus_message_append_args(message, DBUS_TYPE_UINT32, &pid,
                                DBUS_TYPE_INVALID)) {
    fprintf(stderr, "Couldn't append arguments to a dbus message\n");
    dbus_message_unref(message);
    exit(1);
  }

  DBusError error;
  dbus_error_init(&error);
  DBusMessage *reply =
      dbus_connection_send_with_reply_and_block(conn, message, -1, &error);

  dbus_message_unref(message);

  if (dbus_error_is_set(&error)) {
    fprintf(stderr, "Dbus call error. %s: %s\n", error.name, error.message);
    dbus_error_free(&error);
    exit(1);
  }

  char *sessionId;
  if (dbus_message_get_args(reply, &error, DBUS_TYPE_OBJECT_PATH, &sessionId,
                            DBUS_TYPE_INVALID)) {
    sessionId = strdup(sessionId);
  } else {
    fprintf(stderr, "No session id\n");
    exit(1);
  }

  dbus_message_unref(reply);

  if (dbus_error_is_set(&error)) {
    fprintf(stderr, "Dbus args get error. %s: %s\n", error.name, error.message);
    dbus_error_free(&error);
    exit(1);
  }

  return sessionId;
}

void run_env(char *env) {
  char *value = getenv(env);
  if (value != NULL) {
    printf("Running command '%s'\n", value);
    int res = system(value);
    if (res != 0) {
      printf("Command '%s' failed with code %d\n", value, res);
    }
  }
}

int main(void) {
  DBusError err;
  dbus_error_init(&err);

  /* connect to the daemon bus */
  DBusConnection *conn = dbus_bus_get(DBUS_BUS_SYSTEM, &err);
  if (!conn) {
    fprintf(stderr, "Failed to get a session DBus connection: %s\n",
            err.message);
    return 1;
  }

  char *sessionId = get_session_id(conn);

  char *rule;
  asprintf(&rule,
           "type='signal'"
           ",sender='" LOGIND_SERVICE "'"
           ",interface='" LOGIND_SESSION_INTERFACE "'"
           ",member='Unlock'"
           ",path='%s'",
           sessionId);
  dbus_bus_add_match(conn, rule, NULL);

  asprintf(&rule,
           "type='signal'"
           ",sender='" LOGIND_SERVICE "'"
           ",interface='" LOGIND_SESSION_INTERFACE "'"
           ",member='Lock'"
           ",path='%s'",
           sessionId);
  dbus_bus_add_match(conn, rule, NULL);

  dbus_bus_add_match(conn,
                     "type='signal'"
                     ",sender='" LOGIND_SERVICE "'"
                     ",interface='" LOGIND_MANAGER_INTERFACE "'"
                     ",member='PrepareForSleep'",
                     NULL);

  printf("Starting dbus listener\n");
  while (true) {
    dbus_connection_read_write(conn, -1);

    DBusMessage *msg = dbus_connection_pop_message(conn);
    while (msg != NULL) {
      if (dbus_message_is_signal(msg, LOGIND_SESSION_INTERFACE, "Lock")) {
        printf("Got lock message\n");
        run_env("ON_LOCK");
      } else if (dbus_message_is_signal(msg, LOGIND_SESSION_INTERFACE,
                                        "Unlock")) {
        printf("Got unlock message\n");
        run_env("ON_UNLOCK");
      } else if (dbus_message_is_signal(msg, LOGIND_MANAGER_INTERFACE,
                                        "PrepareForSleep")) {
        DBusError error;
        dbus_bool_t active;
        dbus_error_init(&error);
        if (dbus_message_get_args(msg, &error, DBUS_TYPE_BOOLEAN, &active,
                                  DBUS_TYPE_INVALID)) {
          if (active) {
            printf("Got suspend message\n");
            run_env("ON_SUSPEND");
          } else {
            printf("Got resume message\n");
            run_env("ON_RESUME");
          }
        }

        if (dbus_error_is_set(&error)) {
          fprintf(stderr, "Unable to get PrepareForSleep arg. %s: %s\n",
                  err.name, err.message);
          dbus_error_free(&error);
        }
      }

      dbus_message_unref(msg);
      msg = dbus_connection_pop_message(conn);
    }
  }

  return EXIT_SUCCESS;
}