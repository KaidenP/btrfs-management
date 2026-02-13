# BTRFS Management

A collection of scripts to manage BTRFS filesystems, including automated backups, defrag, scrub, and trim operations.

> ⚠️ Status: Early development. No features are currently implemented.

---

## Purpose

BTRFS Management aims to provide a simple, script-driven toolkit for managing BTRFS subvolumes and maintenance tasks in a consistent and automated way.

The project is designed to support:

- Managed subvolumes
- Snapshot-based backups
- Retention policies
- Maintenance automation
- Remote backup integration
- Configurable scheduling

---

## Installation

Clone the `main` branch and run `install.sh` as root:

```bash
git clone -b main https://github.com/KaidenP/btrfs-management.git
cd btrfs-management
sudo ./install.sh
```

---

## Features

### Subvolume & Snapshot Management

- [x] Creation of managed subvolumes  
- [x] Creation of managed subvolumes with a parent of an existing subvolume via rw snapshot  
- [ ] Create read-only snapshots  
- [ ] Incremental snapshot backups  
- [ ] Snapshot retention policies  
- [ ] Automatic pruning of old snapshots  
- [ ] Remote backup support via script specified in config  
- [ ] Compression support  

---

### Maintenance

- [ ] Scheduled scrub  
- [ ] Scheduled defrag  
- [ ] Scheduled trim  
- [ ] Manual maintenance commands  
- [ ] Maintenance logging  
- [ ] Email alerts  

---

### Scheduling & Configuration

- [ ] Crontab integration  
- [ ] Randomized scheduling support  
- [ ] Configurable maintenance windows  
- [ ] Per-subvolume configuration  

---

### Reliability & Safety

- [ ] Locking to prevent concurrent runs  
- [ ] Detailed logging  
- [ ] Exit codes and failure reporting  

---

### Configuration System

- [ ] Global configuration file  
- [ ] Per-directory configuration override  

---

## Reporting

- [ ] Status command  
- [ ] Backup age reporting  
- [ ] Health summary output  

---

## License

MIT License
