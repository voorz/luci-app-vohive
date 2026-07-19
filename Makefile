ROUTER ?= 192.168.6.1
SSH ?= ssh
SCP ?= scp
REMOTE ?= root@$(ROUTER)
IPK_DIR ?= bin/packages
CORE_ARCH ?= arm64

.PHONY: deploy deploy-core

deploy:
	$(SCP) $$(find $(IPK_DIR) -name 'luci-app-vohive_*.ipk' | head -n 1) $(REMOTE):/tmp/
	$(SSH) $(REMOTE) 'opkg install /tmp/luci-app-vohive_*.ipk'

deploy-core:
	$(SCP) $$(find $(IPK_DIR) -name 'vohive-core-$(CORE_ARCH)_*.ipk' | head -n 1) $(REMOTE):/tmp/
	$(SSH) $(REMOTE) 'opkg install /tmp/vohive-core-$(CORE_ARCH)_*.ipk'
