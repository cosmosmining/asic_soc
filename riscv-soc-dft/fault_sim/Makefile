CXX      ?= g++
CXXFLAGS := -O2 -std=c++17 -Wall
.PHONY: all run clean
all: fault_sim

fault_sim: fault_sim.cpp
	$(CXX) $(CXXFLAGS) -o $@ $<

run: fault_sim ## run on a fully-testable and a redundant circuit
	@echo "== c17 (ISCAS'85, fully testable) =="
	./fault_sim c17.bench 256 1
	@echo "== redund (contains untestable faults) =="
	./fault_sim redund.bench 256 1

clean:
	rm -f fault_sim
