include $(TOPDIR)/rules.mk

PKG_NAME:=vohive-core
VOHIVE_VERSION?=v1.6.1
PKG_VERSION:=$(patsubst v%,%,$(VOHIVE_VERSION))
PKG_RELEASE:=1
PKG_LICENSE:=Proprietary
PKG_MAINTAINER:=VoHive
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/vohive-core/Default
  SECTION:=utils
  CATEGORY:=Utilities
  DEPENDS:=
  PKGARCH:=all
endef

define Package/vohive-core-arm64
  $(call Package/vohive-core/Default)
  TITLE:=VoHive core binary (arm64)
  CONFLICTS:=vohive-core vohive-core-amd64 vohive-core-armv7
endef

define Package/vohive-core-amd64
  $(call Package/vohive-core/Default)
  TITLE:=VoHive core binary (amd64)
  CONFLICTS:=vohive-core vohive-core-arm64 vohive-core-armv7
endef

define Package/vohive-core-armv7
  $(call Package/vohive-core/Default)
  TITLE:=VoHive core binary (armv7)
  CONFLICTS:=vohive-core vohive-core-arm64 vohive-core-amd64
endef

define Package/vohive-core-arm64/description
  Preinstalled VoHive linux_arm64 core binary for luci-app-vohive.
endef

define Package/vohive-core-amd64/description
  Preinstalled VoHive linux_amd64 core binary for luci-app-vohive.
endef

define Package/vohive-core-armv7/description
  Preinstalled VoHive linux_armv7 core binary for luci-app-vohive.
endef

define Build/Compile
endef

define Package/vohive-core/install
	$(INSTALL_DIR) $(1)/etc/vohive/bin
	$(INSTALL_BIN) ./files/vohive-$(2) $(1)/etc/vohive/bin/vohive
	if [ -f ./files/.version-$(2) ]; then \
		core_ver=$$(cat ./files/.version-$(2)); \
	else \
		core_ver="$(VOHIVE_VERSION)"; \
	fi; \
	echo "$$core_ver" > $(1)/etc/vohive/bin/version; \
	echo "$(2)" > $(1)/etc/vohive/bin/arch
endef

define Package/vohive-core/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	if [ -x /etc/init.d/vohive ] && /etc/init.d/vohive running >/dev/null 2>&1; then
		/etc/init.d/vohive restart || true
	fi
}
exit 0
endef

define Package/vohive-core-arm64/install
	$(call Package/vohive-core/install,$(1),arm64)
endef

define Package/vohive-core-amd64/install
	$(call Package/vohive-core/install,$(1),amd64)
endef

define Package/vohive-core-armv7/install
	$(call Package/vohive-core/install,$(1),armv7)
endef

define Package/vohive-core-arm64/postinst
$(Package/vohive-core/postinst)
endef

define Package/vohive-core-amd64/postinst
$(Package/vohive-core/postinst)
endef

define Package/vohive-core-armv7/postinst
$(Package/vohive-core/postinst)
endef

$(eval $(call BuildPackage,vohive-core-arm64))
$(eval $(call BuildPackage,vohive-core-amd64))
$(eval $(call BuildPackage,vohive-core-armv7))
