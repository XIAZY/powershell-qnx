// Copyright (c) Xia Zhongyang.
// Licensed under the MIT License.

/*
 * libpsl-native for QNX Neutrino 6.5, in C.
 *
 * PowerShell 7.6 imports 21 functions from libpsl-native (its C++ helper
 * library in PowerShell-Native). QNX 6.5 has no C++ runtime to spare for it,
 * so this file implements those 21 in C, with the semantics of the
 * PowerShell-Native sources (https://github.com/PowerShell/PowerShell-Native;
 * the upstream file for each is named in its comment). Nothing else from that library is exported.
 *
 * QNX differences:
 *  - GetCurrentThreadId: the thread id is pthread_self(), unique in the
 *    process (there is no gettid).
 *  - GetUserFromPid, GetPPid: the process's effective uid and parent come
 *    from devctl(DCMD_PROC_INFO) on /proc/<pid>/as; there is no
 *    /proc/<pid>/stat and no kinfo_proc sysctl.
 *  - GetPwUid, GetGrGid: QNX 6.5 has no strnlen or strndup; the names
 *    getpwuid_r and getgrgid_r return are NUL-terminated in their buffers.
 *  - ForkAndExecProcess (SSH remoting starts ssh with it) uses vfork:
 *    QNX's fork fails with ENOSYS in a multithreaded process. As in
 *    System.Native, vfork is retried while it fails spuriously with EBADF,
 *    every signal is blocked around it, and the child resets custom
 *    handlers to the default and starts with no signal blocked (the
 *    launcher confines the asynchronous signals to a thread of its own).
 *    As upstream, a failure in the child before execve completes (dup2,
 *    chdir, execve itself) comes back as the call's errno, through a
 *    close-on-exec pipe, not as a child that exits.
 */
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <pthread.h>
#include <pwd.h>
#include <signal.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/procfs.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/wait.h>
#ifdef HAVE_SYSLOG_H
#include <syslog.h>
#endif
#include <time.h>
#include <unistd.h>

#define PSL_EXPORT __attribute__((visibility("default")))

/* getcommonstat.h: must match the managed CommonStat layout. */
struct CommonStat
{
    int64_t Inode;
    int Mode;
    int UserId;
    int GroupId;
    int HardlinkCount;
    int64_t Size;
    int64_t AccessTime;
    int64_t ModifiedTime;
    int64_t ChangeTime;
    int64_t BlockSize;
    int DeviceId;
    int NumberOfBlocks;
    int IsDirectory;
    int IsFile;
    int IsSymbolicLink;
    int IsBlockDevice;
    int IsCharacterDevice;
    int IsNamedPipe;
    int IsSocket;
    int IsSetUid;
    int IsSetGid;
    int IsSticky;
};

/*
 * CommonStatStruct in PowerShell (CorePsPlatform.cs) is Sequential, and the
 * runtime lays out managed long fields as this compiler lays out int64_t.
 * On QNX both are 8-byte aligned (QNX's _Int64t is aligned(8), and Mono
 * takes its gint64 alignment from it). Linux x86 aligns them to 4. This struct has the same layout
 * either way, and these asserts keep it so.
 */
_Static_assert(sizeof(struct CommonStat) == 112, "CommonStat size");
_Static_assert(offsetof(struct CommonStat, Inode) == 0, "CommonStat.Inode");
_Static_assert(offsetof(struct CommonStat, Mode) == 8, "CommonStat.Mode");
_Static_assert(offsetof(struct CommonStat, Size) == 24, "CommonStat.Size");
_Static_assert(offsetof(struct CommonStat, AccessTime) == 32, "CommonStat.AccessTime");
_Static_assert(offsetof(struct CommonStat, ModifiedTime) == 40, "CommonStat.ModifiedTime");
_Static_assert(offsetof(struct CommonStat, ChangeTime) == 48, "CommonStat.ChangeTime");
_Static_assert(offsetof(struct CommonStat, BlockSize) == 56, "CommonStat.BlockSize");
_Static_assert(offsetof(struct CommonStat, DeviceId) == 64, "CommonStat.DeviceId");
_Static_assert(offsetof(struct CommonStat, IsSticky) == 108, "CommonStat.IsSticky");

/* setdate.h: packed to 4, as the managed UnixTm. */
#pragma pack(push, 4)
struct private_tm
{
    int32_t Seconds;
    int32_t Minutes;
    int32_t Hour;
    int32_t DayOfMonth;
    int32_t Month;
    int32_t Year;
    int32_t DayOfWeek;
    int32_t DayInYear;
    int32_t IsDst;
};
#pragma pack(pop)
_Static_assert(sizeof(struct private_tm) == 36, "private_tm size");

/* geterrorcategory.cpp: values of System.Management.Automation.ErrorCategory. */
enum
{
    NotSpecified = 0,
    InvalidArgument = 5,
    ObjectNotFound = 13,
    OperationStopped = 14,
    PermissionDenied = 18,
};

PSL_EXPORT int32_t GetErrorCategory(int32_t errnum)
{
    switch (errnum)
    {
    case EINVAL:
        return InvalidArgument;
    case ENOENT:
    case ESRCH:
        return ObjectNotFound;
    case EINTR:
        return OperationStopped;
    case EACCES:
    case EPERM:
        return PermissionDenied;
    default:
        return NotSpecified;
    }
}

/* Fills cs from st; getcommonstat.cpp. */
static void FillCommonStat(const struct stat* st, struct CommonStat* cs)
{
    cs->Inode = st->st_ino;
    cs->Mode = st->st_mode;
    cs->UserId = st->st_uid;
    cs->GroupId = st->st_gid;
    cs->HardlinkCount = st->st_nlink;
    cs->Size = st->st_size;
    cs->AccessTime = st->st_atime;
    cs->ModifiedTime = st->st_mtime;
    cs->ChangeTime = st->st_ctime;
    cs->BlockSize = st->st_blksize;
    cs->DeviceId = st->st_dev;
    cs->NumberOfBlocks = st->st_blocks;
    cs->IsBlockDevice = S_ISBLK(st->st_mode);
    cs->IsCharacterDevice = S_ISCHR(st->st_mode);
    cs->IsDirectory = S_ISDIR(st->st_mode);
    cs->IsFile = S_ISREG(st->st_mode);
    cs->IsNamedPipe = S_ISFIFO(st->st_mode);
    cs->IsSocket = S_ISSOCK(st->st_mode);
    cs->IsSymbolicLink = S_ISLNK(st->st_mode);
    cs->IsSetUid = (st->st_mode & 0xE00) == S_ISUID;
    cs->IsSetGid = (st->st_mode & 0xE00) == S_ISGID;
    cs->IsSticky = (st->st_mode & 0xE00) == S_ISVTX;
}

PSL_EXPORT int GetCommonStat(const char* path, struct CommonStat* cs)
{
    struct stat st;

    errno = 0;
    if (stat(path, &st) != 0)
        return -1;
    FillCommonStat(&st, cs);
    return 0;
}

PSL_EXPORT int GetCommonLStat(const char* path, struct CommonStat* cs)
{
    struct stat st;

    errno = 0;
    if (lstat(path, &st) != 0)
        return -1;
    FillCommonStat(&st, cs);
    return 0;
}

PSL_EXPORT int32_t GetLinkCount(const char* fileName, int32_t* count)
{
    struct stat st;
    int32_t ret;

    errno = 0;
    ret = lstat(fileName, &st);
    *count = ret == 0 ? (int32_t)st.st_nlink : 0;
    return ret;
}

PSL_EXPORT int32_t GetInodeData(const char* fileName, uint64_t* device, uint64_t* inode)
{
    struct stat st;
    int ret;

    errno = 0;
    ret = stat(fileName, &st);
    if (ret == 0)
    {
        *device = st.st_dev;
        *inode = st.st_ino;
    }
    return ret;
}

PSL_EXPORT bool IsSameFileSystemItem(const char* pathOne, const char* pathTwo)
{
    struct stat one, two;

    return stat(pathOne, &one) == 0 && stat(pathTwo, &two) == 0 && one.st_dev == two.st_dev &&
           one.st_ino == two.st_ino;
}

PSL_EXPORT bool IsExecutable(const char* path)
{
    return access(path, X_OK) != -1;
}

PSL_EXPORT int32_t CreateSymLink(const char* link, const char* target)
{
    errno = 0;
    return symlink(target, link);
}

PSL_EXPORT int32_t CreateHardLink(const char* newLink, const char* target)
{
    return link(target, newLink);
}

/* The user or group name from a *_r lookup, malloc'ed; getpwuid.cpp and getgrgid.cpp. */
static long NameBufferSize(int name)
{
    long size = sysconf(name);

    return size < 1 ? 2048 : size;
}

PSL_EXPORT char* GetPwUid(uid_t uid)
{
    long size = NameBufferSize(_SC_GETPW_R_SIZE_MAX);

    for (;;)
    {
        struct passwd pwd, *result = NULL;
        char* buf = calloc((size_t)size, 1);
        char* name = NULL;
        int ret;

        if (buf == NULL)
            return NULL;
        errno = 0;
        ret = getpwuid_r(uid, &pwd, buf, (size_t)size, &result);
        if (ret == ERANGE || (ret != 0 && errno == ERANGE))
        {
            free(buf);
            size *= 2;
            continue;
        }
        if (ret == 0 && result != NULL)
            name = strdup(pwd.pw_name);
        free(buf);
        return name;
    }
}

PSL_EXPORT char* GetGrGid(gid_t gid)
{
    long size = NameBufferSize(_SC_GETGR_R_SIZE_MAX);

    for (;;)
    {
        struct group grp, *result = NULL;
        char* buf = calloc((size_t)size, 1);
        char* name = NULL;
        int ret;

        if (buf == NULL)
            return NULL;
        errno = 0;
        ret = getgrgid_r(gid, &grp, buf, (size_t)size, &result);
        if (ret == ERANGE || (ret != 0 && errno == ERANGE))
        {
            free(buf);
            size *= 2;
            continue;
        }
        if (ret == 0 && result != NULL)
            name = strdup(grp.gr_name);
        free(buf);
        return name;
    }
}

/* A process's procfs_info from devctl(DCMD_PROC_INFO); 0 on success. */
static int GetProcessInfo(pid_t pid, procfs_info* info)
{
    char path[64];
    int fd, err;

    snprintf(path, sizeof path, "/proc/%d/as", (int)pid);
    fd = open(path, O_RDONLY);
    if (fd < 0)
        return -1;
    err = devctl(fd, DCMD_PROC_INFO, info, sizeof *info, NULL);
    close(fd);
    if (err != EOK)
    {
        errno = err;
        return -1;
    }
    return 0;
}

PSL_EXPORT char* GetUserFromPid(pid_t pid)
{
    procfs_info info;

    if (GetProcessInfo(pid, &info) != 0)
        return NULL;
    return GetPwUid(info.euid);
}

PSL_EXPORT pid_t GetPPid(pid_t pid)
{
    procfs_info info;

    if (GetProcessInfo(pid, &info) != 0)
        return (pid_t)UINT32_MAX;
    return info.parent;
}

PSL_EXPORT pid_t GetCurrentThreadId(void)
{
    return (pid_t)pthread_self();
}

PSL_EXPORT bool KillProcess(pid_t pid)
{
    return kill(pid, SIGKILL) == 0;
}

PSL_EXPORT pid_t WaitPid(pid_t pid, bool nohang)
{
    return waitpid(pid, NULL, nohang ? WNOHANG : 0);
}

/* setdate.cpp: sets the system time from a broken-down local time. */
PSL_EXPORT int32_t SetDate(struct private_tm* time)
{
    struct tm native;
    struct timeval tv;
    time_t seconds;

    errno = 0;
    memset(&native, 0, sizeof native);
    native.tm_sec = time->Seconds;
    native.tm_min = time->Minutes;
    native.tm_hour = time->Hour;
    native.tm_mday = time->DayOfMonth;
    native.tm_mon = time->Month;
    native.tm_year = time->Year;
    native.tm_wday = time->DayOfWeek;
    native.tm_yday = time->DayInYear;
    native.tm_isdst = time->IsDst;
    seconds = mktime(&native);
    if (seconds == (time_t)-1)
        return -1;
    tv.tv_sec = seconds;
    tv.tv_usec = 0;
    return settimeofday(&tv, NULL);
}

/* nativesyslog.cpp. Without <syslog.h> there is nothing to log to. */
PSL_EXPORT void Native_OpenLog(const char* ident, int facility)
{
#ifdef HAVE_SYSLOG_H
    openlog(ident, LOG_NDELAY | LOG_PID, facility);
#else
    (void)ident;
    (void)facility;
#endif
}

PSL_EXPORT void Native_SysLog(int32_t priority, const char* message)
{
#ifdef HAVE_SYSLOG_H
    syslog(priority, "%s", message);
#else
    (void)priority;
    (void)message;
#endif
}

PSL_EXPORT void Native_CloseLog(void)
{
#ifdef HAVE_SYSLOG_H
    closelog();
#endif
}

/* createprocess.cpp */
enum { SUPPRESS_PROCESS_SIGINT = 0x00000001 };

/* pipe() with both ends close-on-exec (QNX 6.5 has no pipe2). */
static int PipeCloExec(int fds[2])
{
    if (pipe(fds) != 0)
        return -1;
    if (fcntl(fds[0], F_SETFD, FD_CLOEXEC) != 0 || fcntl(fds[1], F_SETFD, FD_CLOEXEC) != 0) {
        int err = errno;
        close(fds[0]);
        close(fds[1]);
        fds[0] = fds[1] = -1;
        errno = err;
        return -1;
    }
    return 0;
}

static void CloseIfOpen(int fd)
{
    if (fd != -1)
        close(fd);
}

static int Dup2Retry(int from, int to)
{
    int result;
    while ((result = dup2(from, to)) == -1 && errno == EINTR)
        ;
    return result;
}

/* In the child of ForkAndExecProcess: sends errno to the parent through the
 * close-on-exec pipe and exits. Only system calls: the child shares the
 * parent's memory until execve. */
static void ExitToParent(int fd)
{
    int err = errno != 0 ? errno : EIO;
    while (write(fd, &err, sizeof err) == -1 && errno == EINTR)
        ;
    _exit(err);
}

PSL_EXPORT int32_t ForkAndExecProcess(const char* filename, char* const argv[], char* const envp[], const char* cwd,
                                      int32_t redirectStdin, int32_t redirectStdout, int32_t redirectStderr,
                                      int32_t creationFlags, int32_t* childPid, int32_t* stdinFd, int32_t* stdoutFd,
                                      int32_t* stderrFd)
{
    int stdinFds[2] = { -1, -1 }, stdoutFds[2] = { -1, -1 }, stderrFds[2] = { -1, -1 };
    int execFds[2] = { -1, -1 }; /* the child's errno if it fails before execve completes */
    sigset_t all, old;
    pid_t pid;
    int err, childErr;
    ssize_t n;

    if (filename == NULL || argv == NULL || envp == NULL || childPid == NULL || stdinFd == NULL || stdoutFd == NULL ||
        stderrFd == NULL || (redirectStdin & ~1) != 0 || (redirectStdout & ~1) != 0 || (redirectStderr & ~1) != 0) {
        errno = EINVAL;
        goto fail;
    }
    /* Fails the call, rather than the child, when the program cannot run. */
    if (access(filename, X_OK) != 0)
        goto fail;
    if ((redirectStdin && PipeCloExec(stdinFds) != 0) || (redirectStdout && PipeCloExec(stdoutFds) != 0) ||
        (redirectStderr && PipeCloExec(stderrFds) != 0) || PipeCloExec(execFds) != 0)
        goto fail;

    sigfillset(&all);
    pthread_sigmask(SIG_SETMASK, &all, &old);
    while ((pid = vfork()) == -1 && errno == EBADF)
        ;
    if (pid == 0) {
        /* The child shares the parent's memory until execve: only system calls here. */
        struct sigaction dfl, cur;
        sigset_t none;
        memset(&dfl, 0, sizeof dfl);
        dfl.sa_handler = SIG_DFL;
        for (int sig = 1; sig < NSIG; sig++) {
            if (sig == SIGKILL || sig == SIGSTOP)
                continue;
            if (sigaction(sig, NULL, &cur) == 0 && cur.sa_handler != SIG_IGN && cur.sa_handler != SIG_DFL)
                sigaction(sig, &dfl, NULL);
        }
        if (creationFlags & SUPPRESS_PROCESS_SIGINT) {
            struct sigaction ign;
            memset(&ign, 0, sizeof ign);
            ign.sa_handler = SIG_IGN;
            if (sigaction(SIGINT, &ign, NULL) == -1)
                ExitToParent(execFds[1]);
        }
        sigemptyset(&none);
        pthread_sigmask(SIG_SETMASK, &none, NULL);
        if ((redirectStdin && Dup2Retry(stdinFds[0], STDIN_FILENO) == -1) ||
            (redirectStdout && Dup2Retry(stdoutFds[1], STDOUT_FILENO) == -1) ||
            (redirectStderr && Dup2Retry(stderrFds[1], STDERR_FILENO) == -1))
            ExitToParent(execFds[1]);
        if (cwd != NULL && chdir(cwd) == -1)
            ExitToParent(execFds[1]);
        execve(filename, argv, envp);
        ExitToParent(execFds[1]);
    }
    err = errno;
    pthread_sigmask(SIG_SETMASK, &old, NULL);
    if (pid == -1) {
        errno = err;
        goto fail;
    }

    /* As upstream: the write end closes at a successful execve (close-on-exec),
     * so the read sees end-of-file; a child that failed first sent its errno. */
    close(execFds[1]);
    execFds[1] = -1;
    while ((n = read(execFds[0], &childErr, sizeof childErr)) == -1 && errno == EINTR)
        ;
    if (n == (ssize_t)sizeof childErr) {
        while (waitpid(pid, NULL, 0) == -1 && errno == EINTR)
            ;
        errno = childErr;
        goto fail;
    }
    CloseIfOpen(execFds[0]);

    *childPid = pid;
    *stdinFd = stdinFds[1];
    *stdoutFd = stdoutFds[0];
    *stderrFd = stderrFds[0];
    CloseIfOpen(stdinFds[0]);
    CloseIfOpen(stdoutFds[1]);
    CloseIfOpen(stderrFds[1]);
    return 0;

fail:
    err = errno;
    CloseIfOpen(execFds[0]);
    CloseIfOpen(execFds[1]);
    CloseIfOpen(stdinFds[0]);
    CloseIfOpen(stdinFds[1]);
    CloseIfOpen(stdoutFds[0]);
    CloseIfOpen(stdoutFds[1]);
    CloseIfOpen(stderrFds[0]);
    CloseIfOpen(stderrFds[1]);
    if (childPid != NULL)
        *childPid = -1;
    if (stdinFd != NULL)
        *stdinFd = -1;
    if (stdoutFd != NULL)
        *stdoutFd = -1;
    if (stderrFd != NULL)
        *stderrFd = -1;
    errno = err;
    return -1;
}
