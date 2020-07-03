# Runtime-aware paging mode switching

Mechanism and policy to switch between the two existing techniques to virtualize memory (Shadow Page Tables and Two Dimensional Paging), depending on the VM's current workload.

## Includes
- Patch against Linux Kernel [v4.19.67](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/tag/?h=v4.19.67), commit a5aa80588fcd5520ece36121c41b7d8e72245e33
  - Adds paging mode switching capability to KVM.
  - Userspace can choose initial paging mode (default: Shadow Page Tables)
- One-line patch against QEMU [v4.2.92](https://github.com/qemu/qemu/commit/17e1e49814096a3daaa8e5a73acd56a0f30bdc18), commit 17e1e49814096a3daaa8e5a73acd56a0f30bdc18
  - Necessary to start a VM with Two Dimensional Paging
- Script to drive the mechanism
  - Monitors certain metrics with the perf tool
  - Dynamic thresholds-based policy
  - Config file to change various parameters
