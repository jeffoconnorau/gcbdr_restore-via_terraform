moved {
  from = google_compute_instance.vm_debian
  to   = google_compute_instance.vm_debian[0]
}

moved {
  from = google_compute_disk.debian_data_disk
  to   = google_compute_disk.debian_data_disk[0]
}

moved {
  from = google_compute_attached_disk.attach_min_debian
  to   = google_compute_attached_disk.attach_min_debian[0]
}

moved {
  from = google_compute_instance.vm_ubuntu
  to   = google_compute_instance.vm_ubuntu[0]
}

moved {
  from = google_compute_disk.ubuntu_data_disk
  to   = google_compute_disk.ubuntu_data_disk[0]
}

moved {
  from = google_compute_attached_disk.attach_ubuntu_data
  to   = google_compute_attached_disk.attach_ubuntu_data[0]
}

moved {
  from = google_compute_instance.vm_rocky
  to   = google_compute_instance.vm_rocky[0]
}

moved {
  from = google_compute_disk.rocky_data_disk
  to   = google_compute_disk.rocky_data_disk[0]
}

moved {
  from = google_compute_attached_disk.attach_rocky_data
  to   = google_compute_attached_disk.attach_rocky_data[0]
}

# Backup Plans
moved {
  from = google_backup_dr_backup_plan.bp_vms
  to   = google_backup_dr_backup_plan.bp_vms[0]
}

moved {
  from = google_backup_dr_backup_plan.bp_rocky_cmek
  to   = google_backup_dr_backup_plan.bp_rocky_cmek[0]
}

moved {
  from = google_backup_dr_backup_plan.bp_rocky_disk_cmek
  to   = google_backup_dr_backup_plan.bp_rocky_disk_cmek[0]
}

moved {
  from = google_backup_dr_backup_plan.bp_disk
  to   = google_backup_dr_backup_plan.bp_disk[0]
}

# Associations
moved {
  from = google_backup_dr_backup_plan_association.bpa_vm_debian
  to   = google_backup_dr_backup_plan_association.bpa_vm_debian[0]
}

moved {
  from = google_backup_dr_backup_plan_association.bpa_vm_ubuntu
  to   = google_backup_dr_backup_plan_association.bpa_vm_ubuntu[0]
}

moved {
  from = google_backup_dr_backup_plan_association.bpa_vm_rocky
  to   = google_backup_dr_backup_plan_association.bpa_vm_rocky[0]
}

moved {
  from = google_backup_dr_backup_plan_association.bpa_disk_rocky
  to   = google_backup_dr_backup_plan_association.bpa_disk_rocky[0]
}

moved {
  from = google_backup_dr_backup_plan_association.bpa_disk_debian
  to   = google_backup_dr_backup_plan_association.bpa_disk_debian[0]
}
