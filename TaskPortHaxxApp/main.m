//
//  main.m
//  TaskPortHaxxApp
//
//  Created by Duy Tran on 24/10/25.
//

#import <UIKit/UIKit.h>
#import "AppDelegate.h"
#import "Header.h"

#define PT_CONTINUE     7       /* continue the child */
#define PT_ATTACHEXC    14      /* attach to running process with signal exception */

int child_execve(char *path) {
    mach_port_t exception_port = MACH_PORT_NULL;
    mach_port_t fake_bootstrap_port = MACH_PORT_NULL;
    bootstrap_look_up(bootstrap_port, "com.kdt.taskporthaxx.exception_server", &exception_port);
    assert(exception_port != MACH_PORT_NULL);
    bootstrap_look_up(bootstrap_port, "com.kdt.taskporthaxx.fake_bootstrap_port", &fake_bootstrap_port);
    assert(fake_bootstrap_port != MACH_PORT_NULL);
    
    task_set_exception_ports(mach_task_self(),
        EXC_MASK_ALL | EXC_MASK_CRASH,
        exception_port,
        EXCEPTION_STATE_IDENTITY | MACH_EXCEPTION_CODES,
        ARM_THREAD_STATE64);
    task_set_bootstrap_port(mach_task_self(), fake_bootstrap_port);
    
    posix_spawnattr_t attr;
    if(posix_spawnattr_init(&attr) != 0) {
        perror("posix_spawnattr_init");
        return 1;
    }
    
    if(posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETEXEC | POSIX_SPAWN_START_SUSPENDED) != 0) {
        perror("posix_spawnattr_set_flags");
        return 1;
    }
    
    posix_spawnattr_set_registered_ports_np(&attr, (mach_port_t[]){0, bootstrap_port, fake_bootstrap_port}, 3);
    posix_spawnattr_setexceptionports_np(&attr,
        EXC_MASK_ALL | EXC_MASK_CRASH,
        exception_port, EXCEPTION_STATE_IDENTITY | MACH_EXCEPTION_CODES, ARM_THREAD_STATE64);
    char *argv2[] = { path, NULL };
    posix_spawn(NULL, argv2[0], NULL, &attr, argv2, environ);
    perror("posix_spawn");
    return 1;
}

int launch(char *binary, char *arg1, char *arg2, char *arg3, char *arg4, char *arg5, char *arg6, char**env) {
    pid_t pd;
    const char* args[] = {binary, arg1, arg2, arg3, arg4, arg5, arg6,  NULL};
    
    int rv = posix_spawn(&pd, binary, NULL, NULL, (char **)&args, env);
    if (rv) return rv;
    
    return 0;
}


int main(int argc, char * argv[]) {
    if(argc >= 2) {
        if (argc > 2 && strcmp(argv[1], "attach") == 0) {
            pid_t launched_pid = atoi(argv[2]);
            NSLog(@"uid=%d, gid=%d\n", getuid(), getgid());

            int i = ptrace(PT_ATTACHEXC, launched_pid, 0, 0);
            NSLog(@"[w4ever] ptrace attach returned %d\n", i);

            // usleep(1000000);

            // int i = ptrace(PT_ATTACHEXC, launched_pid, 0, 0);
            // NSLog(@"[w4ever] ptrace attach returned %d\n", i);
            // if (i != 0) {
            //     return 1;
            // }
            i =  ptrace(PT_CONTINUE, launched_pid, (void*)1, 0);
            NSLog(@"[w4ever] ptrace PT_CONTINUE returned %d\n", i);

            // // usleep(1000000); // wait for exception to be handled

            // i =  ptrace(PT_DETACH, launched_pid, 0, 0);
            // NSLog(@"[w4ever] ptrace PT_DETACH returned %d\n", i);


            // int res = kill(SIGCONT, launched_pid); // wake up the suspended process

            // int res2 = launch("/var/killall", "-SIGCONT", "com.apple.dt.instruments.dtsecurity", NULL, NULL, NULL, NULL, environ);
            // NSLog(@"killall returned %d", res2);

            // usleep(1000000);

            CFRunLoopRun();
        } else if (strcmp(argv[1], "dtsecurity") == 0) {
            sleep(1); // FIXME: how to sleep until ptrace attach?
            NSString *execDir = @"/var/db/com.apple.xpc.roleaccountd.staging/exec";
            [NSFileManager.defaultManager createDirectoryAtPath:execDir withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *outDir = @"/var/db/com.apple.xpc.roleaccountd.staging/exec/TaskPortHaxx.xpc";
            if (![[NSFileManager defaultManager] fileExistsAtPath:outDir]) {
                NSError *error = nil;
                [NSFileManager.defaultManager copyItemAtPath:@"/System/Library/PrivateFrameworks/DVTInstrumentsFoundation.framework/XPCServices/com.apple.dt.instruments.dtsecurity.xpc" toPath:outDir error:&error];
                if (error) {
                    NSLog(@"Failed to copy dtsecurity.xpc: %@", error);
                    return 1;
                }
            }
            return child_execve("/var/db/com.apple.xpc.roleaccountd.staging/exec/TaskPortHaxx.xpc/com.apple.dt.instruments.dtsecurity");
//        } else if (strcmp(argv[1], "signal") == 0) {
//            assert(argc >= 3);
//            pid_t target_pid = (pid_t)atoi(argv[2]);
//            kill(target_pid, SIGTRAP);
//            return 0;
        }
    }
    
//    if (getuid() != 0) {
//        launchTest(nil);
//        return 0;
//    }
    
    NSString * appDelegateClassName;
    @autoreleasepool {
        // Setup code that might create autoreleased objects goes here.
        appDelegateClassName = NSStringFromClass([AppDelegate class]);
    }
    return UIApplicationMain(argc, argv, nil, appDelegateClassName);
}
