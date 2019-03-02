# unbox

# What is this?
Fork of Fluxbox (with the C++ bits ported to C) integrating (slowly) into 
compton.

# Why?
Becuase I despise the overhead of C++ on my time and want the ability to focus
on the finer bits.

# Purpose
Build a simple unified compositing window manager on top of the compton fork 
by Bernd Busse[tryone144]. Provide OpenGL Filter interface to allow creation
of filters from an abstract API. Refactor fluxbox in C and overlay it on top
of compton to provide better interaction between the window manager and 
features provided by compton.

# Todo:

Provide a socket interface to send command an
Remove all of the command-line args interaction from compton.
