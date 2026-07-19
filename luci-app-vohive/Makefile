include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-vohive
PKG_VERSION?=0.1.39
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=VoHive
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-vohive
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI support for VoHive
  DEPENDS:=+luci-base +rpcd +rpcd-mod-file +curl +ca-bundle +jsonfilter
  PKGARCH:=all
endef

define Package/luci-app-vohive/description
  LuCI management page for installing, configuring, and controlling VoHive.
endef

define Build/Compile
endef

define Package/luci-app-vohive/install
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DIR) $(1)/usr/share/vohive
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/vohive

	$(INSTALL_BIN) ./root/etc/uci-defaults/vohive $(1)/etc/uci-defaults/vohive
	$(INSTALL_BIN) ./root/etc/init.d/vohive $(1)/etc/init.d/vohive
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-vohive.json $(1)/usr/share/luci/menu.d/
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-vohive.json $(1)/usr/share/rpcd/acl.d/
	$(INSTALL_BIN) ./root/usr/share/vohive/*.sh $(1)/usr/share/vohive/
	$(INSTALL_DATA) ./root/www/luci-static/resources/view/vohive/index.js $(1)/www/luci-static/resources/view/vohive/
	echo "$(PKG_VERSION)" > $(1)/usr/share/vohive/plugin_version
endef

define Package/luci-app-vohive/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	mkdir -p /etc/vohive/config /etc/vohive/data /tmp/vohive/logs /tmp/vohive/download
	chmod 0755 /etc/init.d/vohive /usr/share/vohive/*.sh 2>/dev/null || true
	if [ -x /etc/init.d/rpcd ]; then
		/etc/init.d/rpcd reload >/dev/null 2>&1 || /etc/init.d/rpcd restart >/dev/null 2>&1 || true
	fi
}
exit 0
endef

$(eval $(call BuildPackage,luci-app-vohive))
