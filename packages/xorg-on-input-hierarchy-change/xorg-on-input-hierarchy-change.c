#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <stdbool.h>
#include <sys/wait.h>
#include <X11/Xlib.h>
#include <X11/extensions/XInput2.h>

#define DEBOUNCE_MS 64

static void run_command(char **argv) {
    pid_t pid = fork();
    if (pid == 0) {
        execvp(argv[0], argv);
        perror("execvp");
        exit(1);
    } else if (pid > 0) {
        int status;
        waitpid(pid, &status, 0);
    } else {
        perror("fork");
    }
}

static bool is_hierarchy_event(XEvent *xev, int xi_opcode) {
    if (xev->type == GenericEvent && xev->xgeneric.extension == xi_opcode) {
        XGetEventData(xev->xgeneric.display, &xev->xcookie);
        if (xev->xcookie.evtype == XI_HierarchyChanged) {
            XFreeEventData(xev->xgeneric.display, &xev->xcookie);
            return true;
        }
        XFreeEventData(xev->xgeneric.display, &xev->xcookie);
    }
    return false;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <command> [args...]\n", argv[0]);
        return 1;
    }

    Display *dpy = XOpenDisplay(NULL);
    if (!dpy) {
        fprintf(stderr, "Failed to open X display\n");
        return 1;
    }

    int xi_opcode, event, error;
    if (!XQueryExtension(dpy, "XInputExtension", &xi_opcode, &event, &error)) {
        fprintf(stderr, "X Input extension not available.\n");
        return 1;
    }

    int major = 2, minor = 2;
    if (XIQueryVersion(dpy, &major, &minor) != Success) {
        fprintf(stderr, "XI2 not supported. Server supports %d.%d\n", major, minor);
        return 1;
    }

    Window root = DefaultRootWindow(dpy);

    XIEventMask evmask;
    unsigned char mask[(XI_LASTEVENT + 7)/8] = {0};
    evmask.deviceid = XIAllDevices;
    evmask.mask_len = sizeof(mask);
    evmask.mask = mask;
    XISetMask(mask, XI_HierarchyChanged);

    XISelectEvents(dpy, root, &evmask, 1);
    XFlush(dpy);

    printf("Listening for XI_HierarchyChanged events...\n");
    printf("Will run:");
    for (int i = 1; i < argc; i++) {
        printf(" %s", argv[i]);
    }
    printf("\n");

    bool pending = false;

    while (1) {
        XEvent xev;

        if (!pending) {
            // Blocking wait for the first event
            XNextEvent(dpy, &xev);
            fprintf(stderr, "Received event, type: %d\n", xev.type);
            if (is_hierarchy_event(&xev, xi_opcode)) {
                pending = true;
            }
        }

        if (pending) {
            fprintf(stderr, "Debouncing for %d ms\n", DEBOUNCE_MS);
            // Sleep for debounce timeout
            usleep(DEBOUNCE_MS * 1000);


            int drained = 0;
            // Drain all pending events from the queue
            while (XPending(dpy) > 0) {
                XNextEvent(dpy, &xev);
                drained++;
                // Just discard - we already know we need to run the command
            }

            fprintf(stderr, "Drained %d events\n", drained);
            fprintf(stderr, "Executing command\n");

            // Run the command
            run_command(&argv[1]);
            pending = false;
        }
    }

    XCloseDisplay(dpy);
    return 0;
}
