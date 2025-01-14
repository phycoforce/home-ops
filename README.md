<div align="center">

<img src="https://raw.githubusercontent.com/onedr0p/home-ops/main/docs/src/assets/logo.png" align="center" width="144px" height="144px"/>

### My Home Operations Repository :octocat:

_... managed with Flux, Renovate, and GitHub Actions_ 🤖

</div>


### :wrench:&nbsp; Tools

| Tool                                                               | Purpose                                                             |
|--------------------------------------------------------------------|---------------------------------------------------------------------|
| [ansible](https://www.ansible.com)                                 | Preparing Talos Linux and bootstrapping the install                 |
| [flux](https://toolkit.fluxcd.io/)                                 | Operator that manages your k8s cluster based on your Git repository |
| [go-task](https://github.com/go-task/task)                         | A task runner / simpler Make alternative written in Go              |
| [sops](https://github.com/mozilla/sops)                            | Encrypts k8s secrets with GnuPG                                     |


## 💻 Nodes
| Node                          | Hostname        | RAM  | Storage               | Networking                  | Function         | Operating System |
|-------------------------------|-----------------|------|-----------------------|-----------------------------|------------------|------------------|
| Lenovo ThinkCentre M720Q      | Logos           | 64GB | 512GB SSD             | 10GbE X710-DA2              | Control Plane    | Talos Linux      |
| Lenovo ThinkCentre M720Q      | Pneuma          | 64GB | 512GB SSD             | 10GbE x710-DA2              | Control Plane    | Talos Linux      |
| Beelink EQ12                  | Ontos           | 16GB | 512GB SSD             | 2x 2.5Gb 802.3ad Bond       | Control Plane    | Talos Linux      |


## Storage
| Node                          | Hostname        | RAM  | Storage                                                 | Networking       |Function         | Operating System |
|-------------------------------|-----------------|------|---------------------------------------------------------|------------------|-----------------|------------------|
| DIY                           | Aionios         | 32GB | 3 x 20TB CRM HDD ZFS Array, RAIDZ1, 2TB SSD, 512GB NVME |10GbE X710-DA2    |Storage NAS      | Ubuntu Server    |
|                               |                 |      |                                                         |                  |                 |                  |


## Network

| Vendor   | Model                        | Function                                                          |
|----------|------------------------------|-------------------------------------------------------------------|
| Mikrotik | RB5009                       | Edge Router connected to 1Gb Uplink                               |
| Mikrotik | CRS309-1G-8S+IN              | Edge Switch, 10Gb SFP+ Ports                                      |
| Ubiquiti | Unifi U7 Pro                 | Main access point for the house                                   |
| Raspberry| Pi4                          | PiHole & Unbound dedicated device / VPN into network              |

Kubernetes nodes are on their own VLAN which has access to the NAS.

## ☁️ Cloud Dependencies

While most of my infrastructure and workloads are self-hosted I do rely upon the cloud for certain key parts of my setup. This saves me from having to worry about two things. (1) Dealing with chicken/egg scenarios and (2) services I critically need whether my cluster is online or not.

| Service                                                               | Use                                                                | Cost           |
|-----------------------------------------------------------------------|--------------------------------------------------------------------|----------------|
| [Cloudflare](https://www.cloudflare.com/)                             | Domain(s)                                                          | Free           |
| [GitHub](https://github.com/)                                         | Hosting this repository and continuous integration/deployments     | Free           |
| [Oracle Vault](https://www.oracle.com/uk/cloud/)                      | External Secrets                                                   | Free           |
|                                                                       |                                                                    | Total: ~0£/mo  |

