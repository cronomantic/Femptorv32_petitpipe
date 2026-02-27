#include <verilated.h>

#ifndef VM_TOP_HEADER
#define VM_TOP_HEADER "Vtb_top.h"
#endif

#ifndef VM_TOP
#define VM_TOP Vtb_top
#endif

#include VM_TOP_HEADER

int main(int argc, char **argv) {
    VerilatedContext *context = new VerilatedContext();
    context->traceEverOn(true);
    context->commandArgs(argc, argv);

    VM_TOP *top = new VM_TOP{context};

    while (!context->gotFinish()) {
        top->eval();
        context->timeInc(1);
    }

    delete top;
    delete context;
    return 0;
}
