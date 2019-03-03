so you want to build a compositor
26 July 2008 10:02 PM (nargery | gl | tfp | window manager | clutter)

a dialog with someone i don't know

    One way to think about it is that it's like driving a car down the road, and suddenly swapping the steering wheel and brakes out for a tiller and gear shifter. And having to downshift for braking until you learn that the brakes moved to the turn indicator lever. By trial and error. 

That's the internet's Joey Hess, a wonderful writer, who recently switched window managers.

A while back I discussed some new interaction possibilities, and a lot of them hinged on the relation between people and the set of tasks that they do on the computer -- not just the tasks themselves, but the relationships between the tasks, and with focus.

In the free desktop, the locus of this experience is in the window manager. Again, Joey tries to give analogies:

    Another way to look at it is adopting a new philosophy. Or, in some cases a cult. (In some cases, with crazy cult leaders.) Whether they use Windows or a Mac, or Linux, most computer users are members of a big established religion, with some implicit assumptions, like "thy windows shall be overlapping, like papers on the desktop, and thou shalt move them with thy mouse". 

The obvious step if you want to apostatize yourself from the "desktop metaphor", then, is to start hacking window managers. That's how I spent my hack-time in the last month and a half; this writing is an attempt at exegesis.

descent from the mountain, source in hand

I wanted to make a 3D compositing window manager. By 3D, I mean that I wanted the pixels behind the monitor glass to come entirely from one process' OpenGL. By "compositing", I mean that the graphical output from other programs should be redirected through my program. (Compositors don't necessarily need to be implemented with OpenGL; xcompmgr and metacity's compositor are implemented with XRender.)

As an implementation strategy, I took this opportunity to check out Clutter, a GL-based canvas library. What follows is a minimal translation into C of the basic concepts, a broken but fun-to-hack substrate for experimentation.

int main (int argc, char *argv[])
{
    prep_clutter (&argc, &argv);
    prep_root ();
    prep_overlay ();
    prep_stage ();
    prep_input ();

    g_main_loop_run (g_main_loop_new (NULL, FALSE));

    return 0;
}

The main function is pretty simple. We'll be looking at the various functions one by one, but out of order. Let's start with prep_root:

Display *dpy;
Window root;
void prep_root (void)
{
    dpy = clutter_x11_get_default_display ();
    root = DefaultRootWindow (dpy);

    XCompositeRedirectSubwindows (dpy, root, CompositeRedirectAutomatic);
    XSelectInput (dpy, root, SubstructureNotifyMask);
}

This function does two things of interest: first, it tells the X server to redirect output of all windows into backing pixmaps, such that the contents of all mapped windows are available, even if the X server does not think that they are visible. Second, we ask the X server to give us notification when windows come and go, and when they change size.

Window overlay;
void prep_overlay (void)
{
    overlay = XCompositeGetOverlayWindow (dpy, root);
    allow_input_passthrough (overlay);
}

The Composite extension, which allows us to redirect window output, also provides for the existence of an "overlay" window, one that is above all other windows. You can draw directly to the overlay window, but the normal way that you use it is as a parent window -- you create your own window, then reparent it to the overlay.

Composite is pretty cool, except that it is only for output -- that is, you can put the output of a window anywhere, like on the corner of a Compiz cube, but you can't redirect input. By that I mean to say that when you have a rotated compiz cube, you can't interact with the window.

The reason for this is that in order to interact with a window, for example to click a button in it, the X server needs to know how to map the pointer position to a position inside a certain window. This is a tricky problem which needs to be done inside the X server, and no solution to this problem has been merged yet.

This upshot is that what happens today with compositing window managers is that the compositor is very careful to make sure that the underlying X window is exactly positioned behind where the compositor is drawing it. Then, when the user clicks on what essentially is the redirected image of the button, the click actually falls behind the overlay to the actual X window.

Hence, the need to allow events (clicks, pointer motion, etc) to pass through the overlay:

void allow_input_passthrough (Window w)
{
    XserverRegion region = XFixesCreateRegion (dpy, NULL, 0);
 
    XFixesSetWindowShapeRegion (dpy, w, ShapeBounding, 0, 0, 0);
    XFixesSetWindowShapeRegion (dpy, w, ShapeInput, 0, 0, region);

    XFixesDestroyRegion (dpy, region);
}

Basically we call a few undocumented functions, whose goal is to tell the X server that the window in question is not to receive pointer input events.

ClutterActor *stage;
Window stage_win;
void prep_stage (void)
{
    ClutterColor color;

    stage = clutter_stage_get_default ();
    clutter_stage_fullscreen (CLUTTER_STAGE (stage));
    stage_win = clutter_x11_get_stage_window (CLUTTER_STAGE (stage));
    clutter_color_parse ("DarkSlateGrey", &color);
    clutter_stage_set_color (CLUTTER_STAGE (stage), &color);
    
    XReparentWindow (dpy, stage_win, overlay, 0, 0);
    XSelectInput (dpy, stage_win, ExposureMask);
    allow_input_passthrough (stage_win);
    
    clutter_actor_show_all (stage);
}

The next step is to create the clutter "stage", the GLX window to which all of our output will go. We reparent the stage to the overlay, so that it will always be on top, then we allow input events to pass through it as well.

Window input;
void prep_input (void)
{
    XWindowAttributes attr;

    XGetWindowAttributes (dpy, root, &attr);
    input = XCreateWindow (dpy, root,
                           0, 0,  /* x, y */
                           attr.width, attr.height,
                           0, 0, /* border width, depth */
                           InputOnly, DefaultVisual (dpy, 0), 0, NULL);
    XSelectInput (dpy, input,
                  StructureNotifyMask | FocusChangeMask | PointerMotionMask
                  | KeyPressMask | KeyReleaseMask | ButtonPressMask
                  | ButtonReleaseMask | PropertyChangeMask);
    XMapWindow (dpy, input);
    XSetInputFocus (dpy, input, RevertToPointerRoot, CurrentTime);

    attach_event_source ();
}

So if the events fall through the stage, and fall through the overlay, what happens if they don't fall onto a window? Well, you probably want the stage to get the last crack at them, instead of the root window. So hence this terrible trick, making a separate fullscreen input-only window, located below all windows except the root window. We select for all input on this window, so that we get e.g. key presses as well.

Then we install a GSource to process pending X events, redirecting events from the input window to the stage window:

GPollFD event_poll_fd;
static GSourceFuncs event_funcs = {
    event_prepare,
    event_check,
    event_dispatch,
    NULL
};
void attach_event_source (void)
{
    GSource *source;

    source = g_source_new (&event_funcs, sizeof (GSource));

    event_poll_fd.fd = ConnectionNumber (dpy);
    event_poll_fd.events = G_IO_IN;

    g_source_set_priority (source, CLUTTER_PRIORITY_EVENTS);
    g_source_add_poll (source, &event_poll_fd);
    g_source_set_can_recurse (source, TRUE);
    g_source_attach (source, NULL);
}

The prepare() and check() functions are a bit boring, but the dispatch() is worth a look:

static gboolean
event_dispatch (GSource *source, GSourceFunc callback, gpointer user_data)
{
    ClutterEvent *event;
    XEvent xevent;

    clutter_threads_enter ();

    while (!clutter_events_pending () && XPending (dpy)) {
        XNextEvent (dpy, &xevent);
        
        /* here the trickiness */
        if (xevent.xany.window == input) {
            xevent.xany.window = stage_win;
        }

        clutter_x11_handle_event (&xevent);
    }
    
    if ((event = clutter_event_get ())) {
        clutter_do_event (event);
        clutter_event_free (event);
    }

    clutter_threads_leave ();

    return TRUE;
}

We just pick off events, translating the input to the stage window, then give the events to clutter.

Obviously this is a crapload of code just to shunt events around; normally with clutter this is not necessary, but with the X compositing architecture being like it is, we have to roll our own GSource to do the event translation.

This brings me back to the beginning, prep_clutter:

GType texture_pixmap_type;
void prep_clutter (int *argc, char ***argv)
{
    clutter_x11_disable_event_retrieval ();
    clutter_init (argc, argv);
    clutter_x11_add_filter (event_filter, NULL);
    
    if (getenv ("NO_TFP"))
        texture_pixmap_type = CLUTTER_X11_TYPE_TEXTURE_PIXMAP;
    else
        texture_pixmap_type = CLUTTER_GLX_TYPE_TEXTURE_PIXMAP;
}

Here we see that you have to turn off event retrieval before calling clutter_init. Then, we tell Clutter to call a event_filter whenever it gets an X event. I'll get back to that function in a minute.

I suppose that this is as good a time as any to speak of getting window contents into OpenGL. The basic idea is that since we're already storing all of the window's pixels into a backing pixmap (because we are redirecting all output), we don't actually need to transfer the pixels back over the wire to the compositor to have the compositor show the window on the screen. There is a GLX extension, texture from pixmap or TFP, which tells the libGL implementation to get a texture's contents from a pixmap that it already knows about, automatically updating when the pixmap updates.

I digress for a moment to mention something that I did not know when I was getting into all of this. There are two kinds of GLX rendering, direct and indirect. Perhaps you recall these words from running glxinfo to see whether your GL implementation has hardware acceleration or not. In fact, direct vs. indirect exists on a different axis as accelerated vs. software rendering. What "indirect rendering" means is that instead of talking directly to the graphics card through the kernel, a GL application is sending all of its commands over the wire to the X server, which then does the rendering.

But that server-side rendering may be accelerated; indeed, that was the whole point of AIGLX. Technically, with free drivers, this is implemented via having the server's GLX rendering use the same DRI library as libGL does when doing direct rendering. It is the DRI library which does the accelerated communication with the hardware-specific kernel module (the DRM module).

Indirect rendering is slower, however, and it is advantageous to use direct rendering when possible. The problem comes when wanting to use TFP and direct rendering; if I want to bind a GL texture to a pixmap corresponding to some other application, and I am not going to go through the X server to do so, then obviously the kernel itself has to know about X drawables. If I have a named pixmap open from one process that was created from another process, there needs to be a unified memory manager in the kernel:

    It's a crude approximation but the most crucial difference between the nvidia architecture and DRI/DRM is that nvidia actually have a memory manager - and a unified one at that. Without a memory manager it's impossible to allocate offscreen buffers (hence, no pbuffers or fbos) and without a unified memory manager it's impossible to reconcile 2D and 3D operations (hence no redirected Direct Rendering). The Accelerated Indirect GLX feature that the freetards were busy raving about is an endless source of confusion - and ultimately a hack to workaround their lack of a memory manager. 

(That from Linux hater, someone I have warmed to in recent weeks -- I basically agree with Jeremy Allison's position.)

Anyway. You can't do direct TFP with free drivers, is the conclusion of that digression. That's OK, because you can always force indirect rendering via setting LIBGL_ALWAYS_INDIRECT=1 in your environment. But you can't do indirect rendering in Xephyr, only direct, so it's tough to test out window managers. Fortunately, you can get window contents into clutter without TFP, using the fallbacks -- hence the NO_TFP check in prep_clutter.

ánimo, peregrino

OK, at this point we're almost there. Here's the event handler:

static ClutterX11FilterReturn
event_filter (XEvent *ev, ClutterEvent *cev, gpointer unused)
{
    switch (ev->type) {
    case CreateNotify:
        window_created (ev->xcreatewindow.window);
        return CLUTTER_X11_FILTER_REMOVE;

    default:
        return CLUTTER_X11_FILTER_CONTINUE;
    }
}

It's pretty simple, an X event is a tagged union. We respond to the CreateNotify events, which come because we selected for SubstructureNotifyMask on the root window. It turns out we don't need any more events, because clutter handles the rest:

static void
window_created (Window w)
{
    XWindowAttributes attr;    
    ClutterActor *tex;

    if (w == overlay)
        return;

    XGetWindowAttributes (dpy, w, &attr);
    if (attr.class == InputOnly)
        return;
    
    tex = g_object_new (texture_pixmap_type, "window", w,
                        "automatic-updates", TRUE, NULL);

    g_signal_connect (tex, "notify::mapped",
                      G_CALLBACK (window_mapped_changed), NULL);
    g_signal_connect (tex, "notify::window-x",
                      G_CALLBACK (window_position_changed), NULL);
    g_signal_connect (tex, "notify::window-y",
                      G_CALLBACK (window_position_changed), NULL);

    {
        gint mapped, destroyed;
        g_object_get (tex, "mapped", &mapped, NULL);
        if (mapped)
            window_mapped_changed (tex, NULL, NULL);
    }
}

Once we create the window, Clutter will listen for changes in its state -- resizes, maps or unmaps, and ultimately its destruction. (Or at least it will, once #1020 is applied.) Here we connect with the minimum bits necessary to make a window usable. Finally, the functions to show, hide, and resize windows:

static void
window_position_changed (ClutterActor *tex, GParamSpec *pspec, gpointer unused)
{
    gint x, y, window_x, window_y;
    g_object_get (tex, "x", &x, "y", &y, "window-x", &window_x,
                  "window-y", &window_y, NULL);
    if (x != window_x || y != window_y)
        clutter_actor_set_position (tex, window_x, window_y);
}

static void
window_mapped_changed (ClutterActor *tex, GParamSpec *pspec, gpointer unused)
{
    gint mapped;
    g_object_get (tex, "mapped", &mapped, NULL);

    if (mapped){
        clutter_container_add_actor (CLUTTER_CONTAINER (stage), tex);
        clutter_actor_show (tex);
        window_position_changed (tex, NULL, NULL);
    } else {
        clutter_container_remove_actor (CLUTTER_CONTAINER (stage), tex);
    }
}

final notes

Code is here, compile as:

 gcc `pkg-config --cflags --libs clutter-glx-0.8` \
     -o mini-clutter-wm mini-clutter-wm.c 

You might want to run it in a Xephyr; do it with the script here:

 ./run-xephyr ./mini-clutter-wm

Joey again:

    So ideally, "I switched to a new window manager" doesh't mean "my screen has some different widgets on it now". It means "I'm looking at the screen with new eyes." 

This blog is already way too long, so I'll revisit interface concepts at some point in the future. For now I just wanted to pull together this knowledge in one place. Happy hacking!
