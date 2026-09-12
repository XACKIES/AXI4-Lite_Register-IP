SIM ?= verilator

TOPLEVEL_LANG = verilog

VERILOG_SOURCES = $(PWD)/../rtl/axil_register.v

COCOTB_TOPLEVEL = axil_register
COCOTB_TEST_MODULES = test_axil_register

export PYTHONPATH := $(PWD)/../tb:$(PYTHONPATH)

COMPILE_ARGS += --trace

include $(shell cocotb-config --makefiles)/Makefile.sim