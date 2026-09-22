terraform {
  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
    }
  }
  required_version = ">= 0.13"
}

provider "yandex" {
  service_account_key_file = "key.json"
  cloud_id                 = var.cloud_id
  folder_id                = var.folder_id
  zone                     = "ru-central1-a"
}

# Скачиваем образ Ubuntu
data "yandex_compute_image" "ubuntu" {
  family = "ubuntu-2204-lts"
}

# 1. Создаем сеть
resource "yandex_vpc_network" "network" {
  name = "hw-network"
}

resource "yandex_vpc_subnet" "subnet" {
  name           = "hw-subnet"
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.network.id
  v4_cidr_blocks = ["10.5.0.0/24"]
}

# 2. Создаем две виртуалки
resource "yandex_compute_instance" "web_server" {
  count       = 2
  name        = "web-server-${count.index + 1}"
  platform_id = "standard-v1"
  zone        = "ru-central1-a"

  resources {
    cores  = 2
    memory = 2
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu.id # Использование динамического ID
      size     = 15
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.subnet.id
    nat       = true
  }

  metadata = {
    ssh-keys = "ubuntu:${file("/root/.ssh/id_rsa.pub")}"
    user-data = <<EOT
#cloud-config
package_update: true
packages:
  - nginx
runcmd:
  - systemctl start nginx
  - systemctl enable nginx
EOT
  }
}

# 3. Таргер-группа
resource "yandex_lb_target_group" "web_tg" {
  name = "web-target-group"

  dynamic "target" {
    for_each = yandex_compute_instance.web_server
    content {
      subnet_id = yandex_vpc_subnet.subnet.id
      address   = target.value.network_interface.0.ip_address
    }
  }
}

# 4. Балансировщик
resource "yandex_lb_network_load_balancer" "lb" {
  name = "web-balancer"

  listener {
    name = "http-listener"
    port = 80
    external_address_spec {
      ip_version = "ipv4"
    }
  }

  attached_target_group {
    target_group_id = yandex_lb_target_group.web_tg.id

    healthcheck {
      name = "http-healthcheck"
      http_options {
        port = 80
        path = "/"
      }
    }
  }
}

# В конце деплоя выводим адрес балансира
output "balancer_ip" {
  value = [for s in yandex_lb_network_load_balancer.lb.listener : one(s.external_address_spec).address]
}
