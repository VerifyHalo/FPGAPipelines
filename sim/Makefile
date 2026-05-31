SRC     = ../seizure.srcs/sources_1/new/datapath.sv
TB      = tb_datapath.sv
FIFO    = fifo_generator_0.sv
OUT     = run

.PHONY: all sim clean

all: sim

sim:
	iverilog -g2012 -Wall -o $(OUT) $(TB) $(SRC)
	vvp $(OUT)

waves: sim
	/opt/homebrew/bin/gtkwave $(CURDIR)/waves.vcd &

clean:
	rm -f $(OUT) waves.vcd
