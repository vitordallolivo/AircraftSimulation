CC     = gcc
CFLAGS = -O2 -std=c99 -Wall -Wextra
OBJ    = main.o cfg.o util.o ambiente.o aero.o propulsao.o solo.o carga.o \
         trajeto.o piloto.o dinamica.o registro.o estado.o desempenho.o

missao6gdl: $(OBJ)
	$(CC) $(CFLAGS) -o $@ $(OBJ) -lm

%.o: %.c modelo.h
	$(CC) $(CFLAGS) -c $<

clean:
	rm -f $(OBJ) missao6gdl
