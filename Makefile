all:

tinywm:
	clang tinywm.c -I/usr/local/include -L/usr/local/lib -lGL -lX11 -lXext -lm -o tinywm

clutterwm: 
	clang clutterwm.c -I/usr/local/include -L/usr/local/lib -lGL -lX11 -lXext -lm -o clutterwm
