/* Callee-saved registers into a buffer, so a conservative stack scan sees pointers that
 * live only in registers. Built with clang and linked into the prototype. */
void gcproto_save_regs(void **out)
{
    __asm__ volatile(
        "mov %%rbx, 0(%0)\n\t"
        "mov %%rbp, 8(%0)\n\t"
        "mov %%r12, 16(%0)\n\t"
        "mov %%r13, 24(%0)\n\t"
        "mov %%r14, 32(%0)\n\t"
        "mov %%r15, 40(%0)\n\t"
        :
        : "r"(out)
        : "memory");
}
