// SPDX-License-Identifier: GPL-2.0-only
#include <linux/module.h>
#include <linux/security.h>
#include <linux/lsm_hooks.h>
#include <linux/securityfs.h>
#include <linux/fs.h>
#include <linux/sched.h>
#include <linux/uaccess.h>
#include <linux/namei.h>

static struct dentry *my_lsm_dir;

static int my_enabled = 1;
static int my_threshold = 100;
static int my_log_level = 1;

static ssize_t my_read_int(int val, char __user *buf, size_t len, loff_t *ppos)
{
    char tmp[32];
    int n = scnprintf(tmp, sizeof(tmp), "%d\n", val);
    return simple_read_from_buffer(buf, len, ppos, tmp, n);
}

static ssize_t my_write_int(int *p, const char __user *buf, size_t len)
{
    char tmp[32];
    long v;

    if (len >= sizeof(tmp))
        return -EINVAL;
    if (copy_from_user(tmp, buf, len))
        return -EFAULT;
    tmp[len] = '\0';
    if (kstrtol(tmp, 10, &v))
        return -EINVAL;
    if (v < 0)
        return -EINVAL;
    *p = v;
    return len;
}

static ssize_t threshold_read(struct file *f, char __user *b, size_t l, loff_t *o)
{ return my_read_int(my_threshold, b, l, o); }
static ssize_t threshold_write(struct file *f, const char __user *b, size_t l, loff_t *o)
{ return my_write_int(&my_threshold, b, l); }

static const struct file_operations threshold_fops = {
    .read = threshold_read,
    .write = threshold_write,
    .llseek = no_llseek,
};

static ssize_t enable_read(struct file *f, char __user *b, size_t l, loff_t *o)
{ return my_read_int(my_enabled, b, l, o); }
static ssize_t enable_write(struct file *f, const char __user *b, size_t l, loff_t *o)
{ return my_write_int(&my_enabled, b, l); }

static const struct file_operations enable_fops = {
    .read = enable_read,
    .write = enable_write,
    .llseek = no_llseek,
};

static ssize_t log_level_read(struct file *f, char __user *b, size_t l, loff_t *o)
{ return my_read_int(my_log_level, b, l, o); }
static ssize_t log_level_write(struct file *f, const char __user *b, size_t l, loff_t *o)
{ return my_write_int(&my_log_level, b, l); }

static const struct file_operations log_level_fops = {
    .read = log_level_read,
    .write = log_level_write,
    .llseek = no_llseek,
};

static int my_file_open(struct file *file, const struct cred *cred)
{
    char buf[PATH_MAX];
    char *path;
    size_t len;

    if (!READ_ONCE(my_enabled))
        return 0;

    path = d_path(&file->f_path, buf, sizeof(buf));
    if (IS_ERR(path))
        return 0;

    len = strlen(path);

    if (len > READ_ONCE(my_threshold)) {
        if (READ_ONCE(my_log_level) > 0)
            pr_info("my_lsm: deny open pid=%d comm=%s path=%s len=%zu\n",
                    current->pid, current->comm, path, len);
        return -EACCES;
    }

    if (READ_ONCE(my_log_level) > 1)
        pr_info("my_lsm: allow open pid=%d comm=%s path=%s len=%zu\n",
                current->pid, current->comm, path, len);

    return 0;
}

static struct security_hook_list my_hooks[] __lsm_ro_after_init = {
    LSM_HOOK_INIT(file_open, my_file_open),
};

static int __init my_lsm_init(void)
{
    struct dentry *d;

    my_lsm_dir = securityfs_create_dir("my_lsm", NULL);
    if (IS_ERR(my_lsm_dir))
        return PTR_ERR(my_lsm_dir);

    d = securityfs_create_file("enable", 0600, my_lsm_dir, NULL, &enable_fops);
    if (IS_ERR(d)) goto err;

    d = securityfs_create_file("threshold", 0600, my_lsm_dir, NULL, &threshold_fops);
    if (IS_ERR(d)) goto err;

    d = securityfs_create_file("log_level", 0600, my_lsm_dir, NULL, &log_level_fops);
    if (IS_ERR(d)) goto err;

    security_add_hooks(my_hooks, ARRAY_SIZE(my_hooks), "my_lsm");
    pr_info("my_lsm: initialized\n");
    return 0;

err:
    securityfs_remove_recursive(my_lsm_dir);
    return -ENOMEM;
}

DEFINE_LSM(my_lsm) = {
    .name = "my_lsm",
    .init = my_lsm_init,
};

MODULE_LICENSE("GPL");
