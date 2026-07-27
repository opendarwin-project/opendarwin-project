/* Minimal stand-in for <mach/mach_vm.h>: CFUtilities' memory-info and
   discorporate-memory helpers are the only CF users, and OpenDarwin's kernel
   only implements mach_vm_map/allocate/deallocate so far. */
#ifndef CF_OPENDARWIN_MACH_VM_H
#define CF_OPENDARWIN_MACH_VM_H
#include <mach/mach.h>
#include <mach/mach_types.h>
#include <mach/vm_region.h>
typedef uint64_t mach_vm_address_t;
typedef uint64_t mach_vm_size_t;
extern kern_return_t mach_vm_region(vm_map_t, mach_vm_address_t *, mach_vm_size_t *, vm_region_flavor_t, vm_region_info_t, mach_msg_type_number_t *, mach_port_t *);
extern kern_return_t mach_vm_allocate(vm_map_t, mach_vm_address_t *, mach_vm_size_t, int);
extern kern_return_t mach_vm_deallocate(vm_map_t, mach_vm_address_t, mach_vm_size_t);
#endif
