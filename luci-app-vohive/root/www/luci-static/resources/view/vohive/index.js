'use strict';
'require view';
'require form';
'require fs';
'require ui';
'require uci';
'require dom';
'require poll';
'require rpc';

/* Inject indeterminate progress bar animation */
(function() {
	var style = document.createElement('style');
	style.textContent = [
		'@keyframes vohive-indeterminate { 0% { background-position: 200% 0; } 100% { background-position: -200% 0; } }',
		'.cbi-modal > * { max-width: 100%; box-sizing: border-box; }'
	].join('\n');
	document.head.appendChild(style);
})();

function parseJson(text) {
	try {
		return JSON.parse(text || '{}');
	} catch (e) {
		return { ok: false, message: text || e.message };
	}
}

function notifyResult(text) {
	var result = parseJson(text);
	if (result.ok === false)
		ui.addNotification(null, E('p', {}, result.message || _('操作失败')), 'danger');
	else
		ui.addNotification(null, E('p', {}, result.message || _('操作完成')), 'info');
}

function resultDetails(result) {
	if (!result || !result.output)
		return '';

	return E('details', { 'style': 'margin-top:1em;' }, [
		E('summary', {}, _('查看详细输出')),
		E('pre', {
			'style': [
				'white-space: pre-wrap',
				'max-height: 320px',
				'overflow: auto',
				'margin-top: .75em',
				'padding: 1em',
				'border: 1px solid var(--border-color-medium)',
				'border-radius: 6px',
				'background: var(--background-color-low)',
				'font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace',
				'font-size: 12px'
			].join(';')
		}, result.output)
	]);
}

function runScript(path, args) {
	return fs.exec_direct(path, args || []).then(function(text) {
		notifyResult(text);
		window.setTimeout(function() { location.reload(); }, 800);
	}).catch(function(e) {
		ui.addNotification(null, E('p', {}, e.message || String(e)), 'danger');
	});
}

function saveApplyThen(map, fn) {
	return map.save()
		.then(function() { return ui.changes.apply(false); })
		.then(fn);
}

function progressbar(usedKb, totalKb, percent) {
	var used = (parseInt(usedKb) || 0) * 1024;
	var total = (parseInt(totalKb) || 0) * 1024;
	var pc = Math.max(0, Math.min(100, parseInt(percent) || 0));
	var text = total ? '%1024.2mB / %1024.2mB (%d%%)'.format(used, total, pc) : _('未知');

	return E('div', {
		'class': 'cbi-progressbar',
		'title': text
	}, E('div', { 'style': 'width:%.2f%%'.format(pc) }));
}

function memoryText(kb) {
	var value = parseInt(kb) || 0;

	return value ? '%1024.2mB RSS'.format(value * 1024) : _('未运行');
}

function cpuMemoryText(status) {
	var cpuX100 = parseInt(status.cpu_percent_x100);
	var memoryKb = parseInt(status.memory_used_kb) || 0;
	var cpu = isNaN(cpuX100) ? ((parseInt(status.cpu_percent) || 0) * 100) : cpuX100;

	return '%.2f%% / %s'.format(cpu / 100, memoryText(memoryKb));
}

function statusBadge(active) {
	return E('span', {
		'style': 'color:%s; font-weight:700;'.format(active ? '#37a24d' : '#d9534f')
	}, active ? _('运行中') : _('已停止'));
}

var DEFAULT_CORE_REPO = 'https://github.com/voorz/vohive-next';
var DEFAULT_PLUGIN_REPO = 'voorz/luci-app-vohive';

function releaseRepoSlug(repo) {
	return (repo || DEFAULT_CORE_REPO)
		.replace(/^https?:\/\/github\.com\//, '')
		.replace(/^git@github\.com:/, '')
		.replace(/\/$/, '')
		.replace(/\.git$/, '');
}

function releaseLink(repo, version) {
	if (!repo || !/^v[0-9]/.test(version || ''))
		return version;

	return E('a', {
		'href': 'https://github.com/%s/releases/tag/%s'.format(repo, version),
		'target': '_blank',
		'rel': 'noreferrer'
	}, version);
}

function pluginVersionLink(repo, version) {
	if (/^[0-9]/.test(version || ''))
		return releaseLink(repo, 'v' + version);

	return releaseLink(repo, version);
}

function coreArchLabel(arch) {
	return arch && arch != 'unknown' ? 'linux_%s'.format(arch) : _('未知');
}

function loadingText(text) {
	return E('em', { 'class': 'spinning' }, text || _('正在加载...'));
}

function formatBytes(bytes) {
	var value = parseInt(bytes) || 0;

	if (value >= 1024 * 1024)
		return '%1024.2mB'.format(value);

	return '%d KiB'.format(Math.max(0, Math.round(value / 1024)));
}

function formatSpeed(bytes) {
	var value = parseInt(bytes) || 0;

	if (value <= 0)
		return '0 KiB/s';

	if (value >= 1024 * 1024)
		return '%1024.2mB/s'.format(value);

	return '%d KiB/s'.format(Math.max(1, Math.round(value / 1024)));
}

function taskTitle(type) {
	switch (type) {
	case 'install_core':
		return _('在线安装 VoHive 核心');
	case 'upload_core':
		return _('上传安装 VoHive 核心');
	case 'update_plugin':
		return _('更新 LuCI 插件');
	case 'convert_identity':
		return _('转换模块 USB 身份');
	case 'switch_usbnet':
		return _('切换模块 USB 网络模式');
	case 'probe_device':
		return _('探测设备');
	default:
		return _('更新任务');
	}
}

function taskProgressbar(status) {
	var percent = status.state == 'completed' ? 100 : Math.max(0, Math.min(100, parseInt(status.percent) || 0));

	return E('div', {
		'class': 'cbi-progressbar',
		'style': 'margin:.75em 0;',
		'title': '%d%%'.format(percent)
	}, E('div', { 'style': 'width:%.2f%%'.format(percent) }));
}

function taskIndeterminateBar() {
	return E('div', {
		'class': 'cbi-progressbar',
		'style': 'margin:.75em 0; overflow:hidden;'
	}, E('div', {
		'style': [
			'width:100%',
			'height:100%',
			'background:linear-gradient(90deg, transparent 0%, var(--primary-color, #09c) 50%, transparent 100%)',
			'background-size:200% 100%',
			'animation:vohive-indeterminate 1.2s ease-in-out infinite'
		].join(';')
	}));
}

return view.extend({
	logRefreshTimer: null,
	currentLogs: '',
	statusNode: null,
	coreSectionNode: null,
	releasesData: null,
	taskTimer: null,
	taskModalBody: null,
	activeTaskId: null,
	activeTaskType: null,
	taskCompletedHandled: false,
	devicePane: null,
	driverPane: null,
	deviceProbeTimer: null,
	deviceProbeTaskId: null,

	handleSaveApply: function(ev, mode) {
		return this.super('handleSaveApply', [ ev, mode ]).then(function() {
			return fs.exec_direct('/usr/share/vohive/apply_config.sh', []).then(notifyResult);
		});
	},

	load: function() {
		return Promise.all([
			uci.load('vohive'),
			fs.exec_direct('/usr/share/vohive/status.sh', []).catch(function() { return '{}'; }),
			fs.exec_direct('/usr/share/vohive/logs.sh', [ '100' ]).catch(function() { return ''; }),
			fs.exec_direct('/usr/share/vohive/releases.sh', [ '5' ]).catch(function() { return '{"ok":false,"versions":[]}'; }),
			fs.exec_direct('/usr/share/vohive/plugin_status.sh', [ '5' ]).catch(function() { return '{"ok":false}'; }),
			fs.exec_direct('/usr/share/vohive/device_probe.sh', [ 'status' ]).catch(function() { return '{"ok":false}'; })
		]);
	},

	startTask: function(type, args) {
		return fs.exec_direct('/usr/share/vohive/task_start.sh', [ type ].concat(args || []))
			.then(function(text) {
				var result = parseJson(text);
				if (result.ok === false || !result.id) {
					ui.addNotification(null, E('p', {}, result.message || _('任务启动失败')), 'danger');
					return;
				}

				this.showTaskDialog(result.id, type);
			}.bind(this))
			.catch(function(e) {
				ui.addNotification(null, E('p', {}, e.message || String(e)), 'danger');
			});
	},

	restoreRunningTask: function() {
		return fs.exec_direct('/usr/share/vohive/task_status.sh', [])
			.then(function(text) {
				var status = parseJson(text);
				if (status && status.type == 'probe_device')
					return;
				if (status && (status.state == 'running' || status.state == 'starting') && status.id)
					this.showTaskDialog(status.id, status.type, status);
			}.bind(this))
			.catch(function() {});
	},

	showTaskDialog: function(id, type, initialStatus) {
		this.activeTaskId = id;
		this.activeTaskType = type || (initialStatus && initialStatus.type) || 'task';
		this.taskCompletedHandled = false;
		this.taskModalBody = E('div', {});

		ui.showModal(taskTitle(this.activeTaskType), [ this.taskModalBody ]);
		if (initialStatus)
			this.updateTaskDialog(initialStatus);

		this.pollTaskStatus();
		if (this.taskTimer)
			window.clearInterval(this.taskTimer);
		this.taskTimer = window.setInterval(this.pollTaskStatus.bind(this), 1000);
	},

	pollTaskStatus: function() {
		if (!this.activeTaskId)
			return Promise.resolve();

		return fs.exec_direct('/usr/share/vohive/task_status.sh', [ this.activeTaskId ])
			.then(function(text) {
				var status = parseJson(text);
				if (status.ok === false) {
					ui.addNotification(null, E('p', {}, status.message || _('任务状态读取失败')), 'danger');
					return;
				}

				this.updateTaskDialog(status);
				if (status.state == 'completed' || status.state == 'failed' || status.state == 'canceled')
					this.finishTaskPolling(status);
			}.bind(this))
			.catch(function(e) {
				this.updateTaskDialog({ state: 'failed', message: e.message || String(e), log: [] });
				this.finishTaskPolling({ state: 'failed' });
			}.bind(this));
	},

	cancelTask: function() {
		if (!this.activeTaskId)
			return Promise.resolve();

		return fs.exec_direct('/usr/share/vohive/task_cancel.sh', [ this.activeTaskId ])
			.catch(function(e) {
				ui.addNotification(null, E('p', {}, e.message || String(e)), 'danger');
			});
	},

	showUploadCoreDialog: function() {
		var self = this;
		var fileInput = E('input', { 'type': 'file', 'style': 'display:none;' });
		var fileName = E('span', { 'style': 'color:var(--text-color-medium, #999); margin-left:.5em;' }, _('未选择文件'));

		var uploadBtn = E('button', {
			'class': 'btn cbi-button-action',
			'click': function() {
				var file = fileInput.files[0];
				if (!file) {
					fileInput.click();
					return;
				}
				if (file.size > 100 * 1024 * 1024) {
					ui.addNotification(null, E('p', {}, _('文件大小超过 100 MB 限制')), 'danger');
					return;
				}
				ui.hideModal();
				self.uploadCoreFile(file);
			}
		}, _('上传并安装'));

		fileInput.addEventListener('change', function() {
			var file = fileInput.files[0];
			if (file) {
				fileName.textContent = '%s (%s)'.format(file.name, formatBytes(file.size));
				fileName.style.color = 'var(--primary-color, #09c)';
			} else {
				fileName.textContent = _('未选择文件');
				fileName.style.color = 'var(--text-color-medium, #999)';
			}
		});

		ui.showModal(_('本地安装'), [
			E('div', { 'style': 'width:100%; box-sizing:border-box;' }, [
				E('p', { 'style': 'margin-bottom:1em;' }, _('选择本地的 VoHive 核心二进制文件进行上传安装。')),
				E('div', { 'style': 'display:flex; align-items:center; gap:.5em; margin-bottom:1em;' }, [
					E('button', {
						'class': 'btn cbi-button',
						'click': function() { fileInput.click(); }
					}, _('选择文件')),
					fileName
				]),
				E('div', { 'class': 'right' }, [
					E('button', {
						'class': 'btn',
						'click': function() { ui.hideModal(); }
					}, _('取消')),
					' ',
					uploadBtn
				])
			])
		]);
	},

	uploadCoreFile: function(file) {
		var self = this;
		var xhr;
		var uploadPath = '/tmp/vohive/download/vohive-core-upload';

		var progressLabel = E('span', {}, _('准备上传...'));
		var progressFill = E('div', { 'style': 'width:0%;' });
		var progressBar = E('div', { 'class': 'cbi-progressbar', 'style': 'margin:.5em 0;' }, progressFill);

		var cancelBtn = E('button', {
			'class': 'btn cbi-button cbi-button-reset',
			'click': function() {
				if (xhr) xhr.abort();
				ui.hideModal();
				ui.addNotification(null, E('p', {}, _('上传已取消')), 'info');
			}
		}, _('取消'));

		ui.showModal(_('正在上传核心文件'), [
			E('div', { 'style': 'width:100%; box-sizing:border-box;' }, [
				E('p', { 'style': 'margin-bottom:.5em;', 'word-break': 'break-all' }, _('%s (%s)').format(file.name, formatBytes(file.size))),
				progressBar,
				progressLabel,
				E('div', { 'class': 'right', 'style': 'margin-top:.75em;' }, [ cancelBtn ])
			])
		]);

		var formData = new FormData();
		formData.append('sessionid', rpc.getSessionID());
		formData.append('filename', uploadPath);
		formData.append('filedata', file);

		xhr = new XMLHttpRequest();
		xhr.open('POST', L.env.cgi_base + '/cgi-upload', true);
		xhr.upload.onprogress = function(ev) {
			if (ev.lengthComputable) {
				var percent = Math.round(ev.loaded * 100 / ev.total);
				progressFill.style.width = percent + '%';
				progressLabel.textContent = '%s / %s (%d%%)'.format(
					formatBytes(ev.loaded), formatBytes(ev.total), percent
				);
			}
		};
		xhr.onload = function() {
			if (xhr.status === 200) {
				try {
					var res = JSON.parse(xhr.responseText);
					if (res.failure) {
						ui.hideModal();
						ui.addNotification(null, E('p', {}, _('上传失败: %s').format(res.failure)), 'danger');
						return;
					}
				} catch(e) {}
				ui.hideModal();
				self.startTask('upload_core', []);
			} else {
				ui.hideModal();
				ui.addNotification(null, E('p', {}, _('上传失败: HTTP %d').format(xhr.status)), 'danger');
			}
		};
		xhr.onerror = function() {
			ui.hideModal();
			ui.addNotification(null, E('p', {}, _('上传失败: 网络错误')), 'danger');
		};
		xhr.send(formData);
	},

	finishTaskPolling: function(status) {
		if (this.taskTimer) {
			window.clearInterval(this.taskTimer);
			this.taskTimer = null;
		}

		if (this.taskCompletedHandled)
			return;

		this.taskCompletedHandled = true;
		if (status.state == 'completed') {
			if (status.type == 'update_plugin') {
				window.setTimeout(function() { location.reload(); }, 3000);
			} else {
				this.refreshAfterTask(status);
			}
		}
	},

	refreshAfterTask: function(status) {
		var self = this;
		return this.refreshStatus().then(function(freshStatus) {
			if (status.type == 'install_core' || status.type == 'upload_core') {
				return self.refreshCoreSection(freshStatus || {});
			}

			if (self.devicePane && (status.type == 'convert_identity' || status.type == 'switch_usbnet')) {
				self.devicePane.removeAttribute('data-loaded');
				self.devicePane.removeAttribute('data-loading');
				return self.loadDevicePane(self.devicePane);
			}
		});
	},

	refreshCoreSection: function(status) {
		if (!this.coreSectionNode || !this.releasesData)
			return Promise.resolve();

		var self = this;
		return this.renderCoreManagement(status, this.releasesData).then(function(coreEl) {
			dom.content(self.coreSectionNode, coreEl);
		});
	},

	updateTaskDialog: function(status) {
		if (!this.taskModalBody)
			return;

		var state = status.state || 'running';
		var message = status.message || _('正在执行任务');
		var terminal = state == 'completed' || state == 'failed' || state == 'canceled';
		var total = parseInt(status.total) || 0;
		var downloaded = parseInt(status.downloaded) || 0;
		var percent = state == 'completed' ? 100 : (parseInt(status.percent) || 0);
		var hasDownloadStats = total > 0 || downloaded > 0 || status.file;
		var stats = terminal && !hasDownloadStats ? '' : (total > 0
			? '%s / %s · %s · %d%%'.format(formatBytes(downloaded), formatBytes(total), formatSpeed(status.speed_bps), percent)
			: '%s · %s'.format(formatBytes(downloaded), formatSpeed(status.speed_bps)));
		var logLines = status.log || [];
		var success = state == 'completed';
		var pluginDone = success && status.type == 'update_plugin';
		var isInstalling = !terminal && status.stage === 'install';

		dom.content(this.taskModalBody, E('div', { 'style': 'width:100%; max-width:min(620px, 86vw); box-sizing:border-box;' }, [
			E('div', {
				'class': 'alert-message %s'.format(success ? 'success' : (state == 'failed' || state == 'canceled' ? 'warning' : 'info'))
			}, pluginDone ? _('LuCI 插件已更新，3 秒后刷新页面。') : message),
			isInstalling ? E('div', {
				'class': 'alert-message warning',
				'style': 'margin-top:.5em;'
			}, _('正在安装，请勿关闭或刷新页面')) : '',
			isInstalling ? taskIndeterminateBar() : taskProgressbar(status),
			E('div', { 'style': 'display:flex; gap:1em; flex-wrap:wrap; margin-bottom:1em;' }, [
				E('strong', {}, status.stage || state),
				E('span', {}, status.file || ''),
				E('span', {}, stats)
			]),
			E('pre', {
				'style': [
					'white-space: pre-wrap',
					'max-height: 240px',
					'overflow: auto',
					'margin: 0 0 1em 0',
					'padding: 1em',
					'border: 1px solid var(--border-color-medium)',
					'border-radius: 6px',
					'background: var(--background-color-low)',
					'font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace',
					'font-size: 12px'
				].join(';')
			}, logLines.length ? logLines.join('\n') : _('暂无日志')),
			E('div', { 'class': 'right' }, [
				!terminal && status.cancellable ? E('button', {
					'class': 'btn cbi-button cbi-button-reset',
					'click': ui.createHandlerFn(this, this.cancelTask)
				}, _('取消下载')) : '',
				' ',
				pluginDone ? E('button', {
					'class': 'btn cbi-button cbi-button-action',
					'click': function() { location.reload(); }
				}, _('立即刷新')) : E('button', {
					'class': 'btn cbi-button cbi-button-neutral',
					'click': ui.createHandlerFn(this, function() {
						ui.hideModal();
						if (terminal && success)
							return this.refreshAfterTask(status);
					})
				}, terminal ? _('完成') : _('关闭'))
			])
		]));
	},

	/* ---------------------------------------------------------- */
	/* 概览页                                                     */
	/* ---------------------------------------------------------- */

	renderOverview: function(status, releases, plugin, deviceDeps) {
		var self = this;

		this.statusNode = E('div', {}, this.renderStatus(status, releases, plugin));
		this.releasesData = releases;
		this.pluginData = plugin;

		this.coreSectionNode = E('div', {});

		return this.renderCoreManagement(status, releases).then(function(coreEl) {
			dom.content(self.coreSectionNode, coreEl);

			var pluginNode = self.renderPluginManagement(plugin, deviceDeps);

			return E('div', {}, [
				self.statusNode,
				self.coreSectionNode,
				pluginNode
			]);
		});
	},

	renderCoreManagement: function(status, releases) {
		var m = new form.Map('vohive');
		var s, o;
		var repoOk = releases.ok !== false && releases.latest;

		s = m.section(form.NamedSection, 'main', 'vohive', _('核心管理'));
		s.addremove = false;

		o = s.option(form.Value, 'release_repo', _('Release 仓库地址'));
		o.default = DEFAULT_CORE_REPO;
		o.validate = function(section_id, value) {
			return /^(https?:\/\/github\.com\/)?[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/?$/.test(value) || _('必须是 GitHub 仓库地址');
		};

		o = s.option(form.DummyValue, '_repo_status', _('仓库状态'));
		o.rawhtml = true;
		o.cfgvalue = function(section_id) {
			var color = repoOk ? '#37a24d' : '#d9534f';
			var text = repoOk ? _('可用') : _('不可用或无 Release');
			return '<span style="color:%s; font-weight:700;">●</span> <span style="color:%s;">%s</span>'.format(color, color, text);
		};

		o = s.option(form.ListValue, 'core_arch', _('核心架构'));
		o.value('arm64', 'linux_arm64');
		o.value('amd64', 'linux_amd64');
		o.value('armv7', 'linux_armv7');
		o.default = status.core_arch_effective || 'arm64';
		o.cfgvalue = function(section_id) {
			var value = uci.get('vohive', section_id, 'core_arch');
			return value || status.core_arch_effective || 'arm64';
		};
		o.readonly = !repoOk;

		o = s.option(form.ListValue, 'version', _('指定版本'));
		o.value('latest', releases.loading ? _('最新版本（正在加载...）') : (releases.latest ? _('最新版本') + ' (' + releases.latest + ')' : _('最新版本')));
		(releases.versions || []).forEach(function(version) {
			o.value(version, version);
		});
		o.default = 'latest';
		o.readonly = !repoOk;

		o = s.option(form.Button, '_install_core', _('在线安装'));
		o.inputstyle = 'apply';
		o.readonly = !repoOk;
		o.onclick = ui.createHandlerFn(this, function() {
			if (!repoOk)
				return;
			return m.save().then(function() {
				var version = uci.get('vohive', 'main', 'version') || 'latest';
				var repo = uci.get('vohive', 'main', 'release_repo') || DEFAULT_CORE_REPO;
				var arch = uci.get('vohive', 'main', 'core_arch') || '';
				return this.startTask('install_core', [ version, repo, arch ]);
		}.bind(this));
	});

		o = s.option(form.Button, '_upload_core', _('本地安装'));
		o.inputstyle = 'action';
		o.onclick = ui.createHandlerFn(this, function() {
			return this.showUploadCoreDialog();
		});

		return m.render().then(function(node) {
			node.querySelectorAll('input[id$=".release_repo"]').forEach(function(input) {
				input.setAttribute('autocomplete', 'url');
			});
			return node;
		});
	},

	renderPluginManagement: function(plugin, deviceDeps) {
		var repo = plugin.repo || DEFAULT_PLUGIN_REPO;
		var current = plugin.current || _('未知');
		var latest = plugin.loading ? loadingText(_('正在加载...')) : pluginVersionLink(repo, plugin.latest || _('未知'));
		if (!plugin.loading && plugin.latest && plugin.ok !== false)
			latest = E('span', {}, [
				latest,
				' ',
				E('span', { 'style': 'color:%s;'.format(plugin.has_update ? '#d58512' : '#37a24d') }, plugin.has_update ? _('(可更新)') : _('(已是最新版本)'))
			]);

		var depRows = [];
		if (deviceDeps) {
			var deps = [
				{ name: 'kmod-usb-serial', installed: deviceDeps.serial_driver_installed, install_action: 'install_serial_drivers' },
				{ name: 'kmod-usb-serial-option', installed: deviceDeps.option_driver_installed, install_action: 'install_serial_drivers' },
				{ name: 'socat', installed: deviceDeps.socat_installed, install_action: 'install_socat' }
			];
			depRows = deps.map(function(dep) {
				var status;
				if (dep.installed) {
					status = E('span', { 'style': 'color:#37a24d; font-weight:700;' }, _('已安装'));
				} else {
					status = E('button', {
						'class': 'btn cbi-button cbi-button-action',
						'click': ui.createHandlerFn(this, function() {
							return runScript('/usr/share/vohive/device_tools.sh', [ dep.install_action ]);
						})
					}, _('安装依赖'));
				}
				return E('tr', {}, [ E('td', { 'style': 'width:30%;' }, dep.name), E('td', {}, status) ]);
			}.bind(this));
		}

		var tableRows = [
			E('tr', {}, [ E('td', { 'style': 'width:30%;' }, _('当前版本')), E('td', {}, pluginVersionLink(repo, current)) ]),
			E('tr', {}, [ E('td', { 'style': 'width:30%;' }, _('最新版本')), E('td', {}, latest) ])
		].concat(depRows);

		var nodes = [
			E('div', { 'class': 'cbi-section' }, [
				E('h3', { 'style': 'margin-bottom:.75em;' }, _('插件与依赖')),
				E('table', { 'class': 'table' }, tableRows),
				E('button', {
					'class': 'btn cbi-button cbi-button-action',
					'style': 'margin-top:.75em;',
					'disabled': (plugin.ok !== false && !plugin.has_update) ? true : null,
					'click': ui.createHandlerFn(this, function() {
						return this.startTask('update_plugin', []);
					})
				}, (plugin.ok !== false && !plugin.has_update) ? _('无需更新') : _('更新 LuCI 插件'))
			])
		];

		if (plugin.ok === false && !plugin.loading)
			nodes.unshift(E('div', { 'class': 'alert-message warning' }, plugin.message || _('无法获取插件版本信息。')));

		return E('div', {}, nodes);
	},

	/* ---------------------------------------------------------- */
	/* 设备管理 Tab                                               */
	/* ---------------------------------------------------------- */

	renderDeviceProbeLoading: function(devicePane, started, status) {
		var elapsed = Math.max(0, Math.floor((Date.now() - started) / 1000));
		var message = status && status.message ? status.message : _('正在探测设备...');
		var stage = status && status.stage ? status.stage : 'probe';

		dom.content(devicePane, E('div', { 'class': 'cbi-section' }, [
			loadingText(message),
			E('p', { 'style': 'margin-top:.75em; color:var(--text-color-medium);' },
				_('当前阶段：%s，已等待 %d 秒。设备重新枚举时可能需要更久。').format(stage, elapsed))
		]));
	},

	fetchDeviceProbeCache: function(devicePane, result) {
		return fs.exec_direct('/usr/share/vohive/device_probe.sh', [ 'cache' ])
			.catch(function(e) {
				return JSON.stringify({ ok: false, message: e.message || String(e), ports: [] });
			})
			.then(function(text) {
				var data = parseJson(text);
				devicePane.setAttribute('data-loaded', 'true');
				devicePane.removeAttribute('data-loading');
				this.deviceProbeTaskId = null;
				dom.content(devicePane, this.renderDeviceTools(devicePane, data, result));
			}.bind(this));
	},

	finishDeviceProbeLoading: function() {
		if (this.deviceProbeTimer) {
			window.clearInterval(this.deviceProbeTimer);
			this.deviceProbeTimer = null;
		}
	},

	pollDeviceProbe: function(devicePane, id, started, result) {
		return fs.exec_direct('/usr/share/vohive/task_status.sh', [ id ])
			.then(function(text) {
				var status = parseJson(text);
				var terminal = status.state == 'completed' || status.state == 'failed' || status.state == 'canceled';

				if (this.deviceProbeTaskId != id)
					return;

				if (status.type && status.type != 'probe_device') {
					this.finishDeviceProbeLoading();
					this.deviceProbeTaskId = null;
					devicePane.removeAttribute('data-loading');
					dom.content(devicePane, this.renderDeviceTools(devicePane, {
						ok: false,
						message: _('已有其它后台任务正在运行，请稍后再探测设备。'),
						ports: []
					}, result));
					return;
				}

				this.renderDeviceProbeLoading(devicePane, started, status);
				if (!terminal)
					return;

				this.finishDeviceProbeLoading();
				if (status.state == 'completed')
					return this.fetchDeviceProbeCache(devicePane, result);

				devicePane.removeAttribute('data-loading');
				dom.content(devicePane, this.renderDeviceTools(devicePane, {
					ok: false,
					message: status.message || _('设备探测失败。'),
					ports: []
				}, result));
			}.bind(this))
			.catch(function(e) {
				this.finishDeviceProbeLoading();
				this.deviceProbeTaskId = null;
				devicePane.removeAttribute('data-loading');
				dom.content(devicePane, this.renderDeviceTools(devicePane, {
					ok: false,
					message: e.message || String(e),
					ports: []
				}, result));
			}.bind(this));
	},

	loadDevicePane: function(devicePane, result) {
		var started = Date.now();

		this.finishDeviceProbeLoading();

		devicePane.setAttribute('data-loading', 'true');
		this.renderDeviceProbeLoading(devicePane, started);

		return fs.exec_direct('/usr/share/vohive/task_start.sh', [ 'probe_device' ])
			.catch(function(e) {
				return JSON.stringify({ ok: false, message: e.message || String(e) });
			})
			.then(function(text) {
				var task = parseJson(text);

				if (task.ok === false || !task.id) {
					devicePane.removeAttribute('data-loading');
					dom.content(devicePane, this.renderDeviceTools(devicePane, {
						ok: false,
						message: task.message || _('设备探测启动失败。'),
						ports: []
					}, result));
					return;
				}

				this.deviceProbeTaskId = task.id;
				this.pollDeviceProbe(devicePane, task.id, started, result);
				this.deviceProbeTimer = window.setInterval(function() {
					this.pollDeviceProbe(devicePane, task.id, started, result);
				}.bind(this), 1000);
			}.bind(this));
	},

	runDeviceTool: function(devicePane, args, confirmText) {
		if (confirmText && !window.confirm(confirmText))
			return Promise.resolve();

		dom.content(devicePane, E('div', { 'class': 'cbi-section' }, loadingText(_('正在执行操作...'))));

		return fs.exec_direct('/usr/share/vohive/device_tools.sh', args)
			.catch(function(e) {
				return JSON.stringify({ ok: false, message: e.message || String(e) });
			})
			.then(function(text) {
				var result = parseJson(text);
				ui.addNotification(null, E('p', {}, result.message || (result.ok === false ? _('操作失败') : _('操作完成'))), result.ok === false ? 'danger' : 'info');
				return this.loadDevicePane(devicePane, result);
			}.bind(this));
	},

	deviceIdentityLabel: function(port) {
		if (port.identity_label && port.identity_label != _('未知'))
			return port.identity_label;
		return port.usb_config || _('未知');
	},

	renderIdentityToggle: function(devicePane, port) {
		if (port.status != 'ok' || !port.can_config)
			return '-';

		var isDji = port.identity == 'dji';
		var currentLabel = port.identity_label || _('未知');
		var target = isDji ? 'ec25' : 'dji';
		var targetLabel = isDji ? _('Quectel EC25') : _('DJI 4G Module');
		var btnClass = isDji ? 'cbi-button-apply' : 'cbi-button-reset';

		return E('div', { 'style': 'display:flex; gap:.5em; align-items:center; flex-wrap:wrap;' }, [
			E('span', { 'style': 'font-weight:700;' }, _('当前：%s').format(currentLabel)),
			E('button', {
				'class': 'btn cbi-button %s'.format(btnClass),
				'click': ui.createHandlerFn(this, function() {
					if (!window.confirm(_('确认要将 %s 的身份切换为 %s 吗？\n\n此操作会写入模块内部 USB 配置，并重启模块。执行前会停止 VoHive，完成后会重新启动 VoHive。').format(port.port, targetLabel)))
						return Promise.resolve();
					return this.startTask('convert_identity', [ port.port, target ]);
				})
			}, _('切换至 %s').format(targetLabel))
		]);
	},

	renderUsbnetSelect: function(devicePane, port) {
		var modes = port.usbnet_profile == 'dji' ? [
			[ 'dji', '0', _('DJI') ],
			[ 'dji_rndis', '1', 'RNDIS' ],
			[ 'dji_ecm', '2', 'ECM' ],
			[ 'dji_ncm', '3', 'NCM' ],
			[ 'dji_mbim', '4', 'MBIM' ]
		] : [
			[ 'qmi', '0', 'QMI' ],
			[ 'ecm', '1', 'ECM' ],
			[ 'mbim', '2', 'MBIM' ]
		];

		if (port.status != 'ok' || !port.can_config || port.usbnet == null || port.usbnet === '')
			return '-';

		var select = E('select', { 'class': 'cbi-input-select', 'style': 'min-width:6em;' });
		modes.forEach(function(mode) {
			select.appendChild(E('option', {
				'value': mode[0],
				'selected': String(port.usbnet) == mode[1] ? 'selected' : null
			}, mode[2]));
		});

		select.addEventListener('change', ui.createHandlerFn(this, function(ev) {
			var target = ev.target.value;
			var label = modes.filter(function(m) { return m[0] == target; })[0];
			if (!label)
				return Promise.resolve();
			if (!window.confirm(_('确认要将 %s 的 USB 网络模式切换为 %s 吗？\n\n此操作会写入模块内部配置，并重启模块。执行前会停止 VoHive，完成后会重新启动 VoHive。').format(port.port, label[2])))
				return Promise.resolve();
			return this.startTask('switch_usbnet', [ port.port, target ]);
		}));

		return select;
	},

	renderInfoGrid: function(rows) {
		var children = [];

		rows.forEach(function(row) {
			children.push(E('div', { 'style': 'font-weight:700;' }, row[0]));
			children.push(E('div', { 'style': 'word-break:break-word;' }, row[1] || '-'));
		});

		return E('div', {
			'style': 'display:grid; grid-template-columns:minmax(8em, 14em) minmax(0, 1fr); gap:.45em 1em; align-items:start;'
		}, children);
	},

	renderPortCard: function(devicePane, port, index) {
		var summary = port.summary || {};
		var details = port.details || [];
		var statusColor = port.status == 'ok' ? '#37a24d' : '#d9534f';
		var title = _('串口 %d').format(index);
		var portPath = port.port || '-';
		var usbLabel = port.usb_vidpid ? '%s · %s'.format(port.usb_vidpid, port.usb_identity_label || _('未知')) : _('未读取到 USB VID/PID');

		var infoRows = [
			[ _('串口路径'), portPath ],
			[ _('端口角色'), port.primary_at ? _('主 AT 口') : (port.status == 'ok' ? _('附属 AT 口') : _('非 AT 口') ) ],
			[ _('AT 身份'), port.identity_label || _('未知') ],
			[ _('模块'), port.module || summary.model || '-' ],
			[ _('固件'), summary.firmware || '-' ],
			[ _('SIM'), summary.sim || '-' ],
			[ _('信号'), summary.signal || '-' ],
			[ _('运营商'), summary.operator || '-' ],
			[ _('当前网络'), summary.network || '-' ],
			[ _('USB 网络模式'), port.usbnet_label || _('未知') ],
			[ _('IMEI'), '-' ],
			[ _('ICCID'), '-' ],
			[ _('IP 地址'), '-' ],
			[ _('温度'), '-' ],
			[ _('USB 产品'), '-' ],
			[ _('USB 序列号'), '-' ]
		];

		details.forEach(function(item) {
			for (var i = 0; i < infoRows.length; i++) {
				if (infoRows[i][0] === item.label) {
					infoRows[i][1] = item.value || '-';
					return;
				}
			}
		});

		infoRows.push([ _('USB 网络模式切换'), this.renderUsbnetSelect(devicePane, port) ]);
		infoRows.push([ _('身份切换'), this.renderIdentityToggle(devicePane, port) ]);

		var children = [
			E('div', { 'style': 'display:flex; justify-content:space-between; gap:1em; flex-wrap:wrap; align-items:flex-start;' }, [
				E('div', {}, [
					E('h4', { 'style': 'margin:0 0 .35em 0;' }, title),
					E('div', { 'style': 'color:var(--text-color-medium);' }, usbLabel)
				]),
				E('div', { 'style': 'font-weight:700; color:%s;'.format(statusColor) }, port.status == 'ok' ? _('AT 可用') : _('无响应'))
			])
		];

		if (port.identity_mismatch)
			children.push(E('div', { 'class': 'alert-message warning', 'style': 'margin-top:.75em;' }, _('sysfs VID/PID 与 AT 内部 USB 配置不一致，请确认模块重启完成后再执行危险操作。')));

		children.push(this.renderInfoGrid(infoRows));

		children.push(
			E('details', { 'style': 'margin-top:1em;' }, [
				E('summary', {}, _('完整 AT 输出')),
				E('pre', {
					'style': [
						'white-space: pre-wrap',
						'max-height: 320px',
						'overflow: auto',
						'margin-top: .75em',
						'padding: 1em',
						'border: 1px solid var(--border-color-medium)',
						'border-radius: 6px',
						'background: var(--background-color-low)',
						'font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace',
						'font-size: 12px'
					].join(';')
				}, port.output || '-')
			])
		);

		return E('div', {
			'class': 'cbi-section',
			'style': 'border:1px solid var(--border-color-medium); border-radius:6px; padding:1em; margin-bottom:1em;'
		}, children);
	},

	renderProbeCards: function(devicePane, data) {
		var ports = data.ports || [];
		var validPorts = ports.filter(function(port) { return port.status == 'ok'; });

		if (!ports.length)
			return E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('串口探测')),
				E('div', { 'class': 'alert-message warning' }, _('未发现 /dev/ttyUSB* 串口。请确认模块已接入，且串口驱动已安装。'))
			]);

		if (!validPorts.length)
			return E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('串口探测')),
				E('div', { 'class': 'alert-message warning' }, _('未发现可用的 AT 串口。请确认模块已接入并响应 AT 命令。'))
			]);

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('串口探测')),
			E('div', {}, validPorts.map(function(port, i) {
				return this.renderPortCard(devicePane, port, i + 1);
			}.bind(this)))
		]);
	},

	renderDeviceTools: function(devicePane, data, result) {
		var nodes = [
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'style': 'display:flex; align-items:center; justify-content:space-between; gap:1em; flex-wrap:wrap;' }, [
					E('h3', { 'style': 'margin-bottom:.75em;' }, _('设备管理')),
					E('button', {
						'class': 'btn cbi-button cbi-button-reload',
						'click': ui.createHandlerFn(this, function() {
							return this.loadDevicePane(devicePane);
						})
					}, _('重新探测'))
				]),
				E('p', { 'style': 'margin:0; color:var(--text-color-medium);' },
					_('通过串口 AT 命令探测模块信息，并对 USB 身份和网络模式进行配置。'))
			])
		];

		if (result)
			nodes.push(E('div', { 'class': 'alert-message %s'.format(result.ok === false ? 'danger' : 'success') }, [
				E('p', {}, result.message || (result.ok === false ? _('操作失败') : _('操作完成'))),
				resultDetails(result)
			]));

		if (data.ok === false)
			nodes.push(E('div', { 'class': 'alert-message danger' }, data.message || _('设备探测失败。')));

		if (!data.socat_installed && !(data.stty_available && data.timeout_available))
			nodes.push(E('div', { 'class': 'alert-message warning' }, _('当前系统缺少可用的串口读取工具。请安装 socat 后重试。')));

		nodes.push(this.renderProbeCards(devicePane, data));
		return E('div', {}, nodes);
	},

	/* ---------------------------------------------------------- */
	/* 网络管理 Tab                                               */
	/* ---------------------------------------------------------- */

	loadNetworkStatus: function() {
		return fs.exec_direct('/usr/share/vohive/network_status.sh', [])
			.catch(function(e) {
				return JSON.stringify({ ok: false, message: e.message || String(e) });
			})
			.then(function(text) {
				return parseJson(text);
			});
	},

	renderNetworkContent: function(status) {
		var self = this;
		var nodes = [];

		if (!status || status.ok === false) {
			nodes.push(E('div', { 'class': 'cbi-section' }, [
				E('em', {}, status && status.message ? status.message : _('无法获取网络状态'))
			]));
			return E('div', {}, nodes);
		}

		var vohiveRunning = status.vohive_running;
		var dataConnected = status.data_connected;
		var netConfigured = status.netifd_configured;
		var fwConfigured = status.firewall_configured;
		var integrated = netConfigured && fwConfigured;

		/* Connection status section */
		var connRows = [];

		connRows.push(E('tr', {}, [
			E('td', { 'style': 'width:30%;' }, _('核心状态')),
			E('td', {}, E('span', {
				'style': 'color:%s; font-weight:700;'.format(vohiveRunning ? '#37a24d' : '#d9534f')
			}, vohiveRunning ? _('运行中') : _('未运行')))
		]));

		connRows.push(E('tr', {}, [
			E('td', {}, _('网络服务')),
			E('td', {}, E('span', {
				'style': 'color:%s; font-weight:700;'.format(status.network_connected ? '#37a24d' : '#d9534f')
			}, status.network_connected ? _('已启用') : _('已禁用')))
		]));

		connRows.push(E('tr', {}, [
			E('td', {}, _('数据连接')),
			E('td', {}, E('span', {
				'style': 'color:%s; font-weight:700;'.format(dataConnected ? '#37a24d' : '#d9534f')
			}, dataConnected ? _('已连接') : _('未连接')))
		]));

		if (status.interface) {
			connRows.push(E('tr', {}, [
				E('td', {}, _('网络接口')),
				E('td', { 'style': 'font-family:monospace;' }, status.interface)
			]));
		}

		if (status.wwan_ipv4) {
			connRows.push(E('tr', {}, [
				E('td', {}, _('IP 地址')),
				E('td', { 'style': 'font-family:monospace;' }, status.wwan_ipv4)
			]));
		}

		if (status.operator) {
			connRows.push(E('tr', {}, [
				E('td', {}, _('运营商')),
				E('td', {}, '%s%s'.format(
					status.operator,
					status.network_mode ? ' (' + status.network_mode + ')' : ''
				))
			]));
		}

		if (status.signal_dbm) {
			var signalDbm = parseInt(status.signal_dbm);
			var signalQuality = signalDbm >= -70 ? _('优秀') : (signalDbm >= -85 ? _('良好') : (signalDbm >= -100 ? _('一般') : _('较弱')));
			connRows.push(E('tr', {}, [
				E('td', {}, _('信号强度')),
				E('td', {}, '%s dBm (%s)'.format(status.signal_dbm, signalQuality))
			]));
		}

		nodes.push(E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('连接状态')),
			E('table', { 'class': 'table' }, connRows)
		]));

		/* Router integration section */
		var integRows = [];

		integRows.push(E('tr', {}, [
			E('td', { 'style': 'width:30%;' }, _('网络接口配置')),
			E('td', {}, E('span', {
				'style': 'color:%s; font-weight:700;'.format(netConfigured ? '#37a24d' : '#d9534f')
			}, netConfigured ? _('已创建 (%s)').format(status.netifd_device || 'vohive') : _('未创建')))
		]));

		integRows.push(E('tr', {}, [
			E('td', {}, _('防火墙 NAT')),
			E('td', {}, E('span', {
				'style': 'color:%s; font-weight:700;'.format(fwConfigured ? '#37a24d' : '#d9534f')
			}, fwConfigured ? _('已加入 wan 域') : _('未配置')))
		]));

		if (status.default_routes && status.default_routes.length > 0) {
			var routeText = status.default_routes.map(function(r) {
				return '%s (metric %s)'.format(r.dev, r.metric);
			}).join(' · ');
			integRows.push(E('tr', {}, [
				E('td', {}, _('默认路由')),
				E('td', { 'style': 'font-family:monospace; font-size:12px;' }, routeText)
			]));
		}

		if (integrated) {
			var isPrimary = status.is_primary;

			var metricSelect = E('select', { 'class': 'cbi-input-select', 'style': 'min-width:10em;' });
			var optBackup = E('option', { 'value': 'backup' }, _('备用（其他 WAN 优先）'));
			var optPrimary = E('option', { 'value': 'primary' }, _('主力（4G/5G 优先）'));
			var optCustom = E('option', { 'value': 'custom' }, _('自定义'));
			if (isPrimary) {
				optPrimary.setAttribute('selected', 'selected');
			} else {
				optBackup.setAttribute('selected', 'selected');
			}
			metricSelect.appendChild(optBackup);
			metricSelect.appendChild(optPrimary);
			metricSelect.appendChild(optCustom);

			var customInput = E('input', {
				'type': 'number', 'min': '0', 'max': '65535',
				'class': 'cbi-input-text',
				'style': 'width:6em; display:none;',
				'placeholder': 'metric'
			});

			metricSelect.addEventListener('change', function(ev) {
				customInput.style.display = (ev.target.value === 'custom') ? 'inline-block' : 'none';
			});

			var applyBtn = E('button', {
				'class': 'btn cbi-button cbi-button-apply',
				'click': ui.createHandlerFn(self, function() {
					var mode = metricSelect.value;
					var label;
					if (mode === 'custom') {
						mode = customInput.value;
						if (!mode || mode < 0 || mode > 65535) {
							ui.addNotification(null, E('p', {}, _('请输入有效的 metric 值（0-65535）')), 'danger');
							return Promise.resolve();
						}
						label = _('其他 WAN metric=%s').format(mode);
					} else if (mode === 'primary') {
						label = _('主力（4G/5G 优先）');
					} else {
						label = _('备用（其他 WAN 优先）');
					}
					if (!window.confirm(_('确认将路由优先级设为 %s 吗？').format(label)))
						return Promise.resolve();
					return self.networkAction('set_metric', [ mode ]);
				})
			}, _('应用'));

			integRows.push(E('tr', {}, [
				E('td', {}, _('路由优先级')),
				E('td', { 'style': 'white-space:nowrap;' }, [ metricSelect, ' ', customInput, ' ', applyBtn ])
			]));
		} else {
			integRows.push(E('tr', {}, [
				E('td', {}, _('路由优先级')),
				E('td', {}, E('span', {
					'style': 'color:%s; font-weight:700;'.format(status.is_primary ? '#37a24d' : '#d58512')
				}, status.is_primary ? _('主力（4G/5G 优先）') : _('备用（其他 WAN 优先）')))
			]));
		}

		nodes.push(E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('路由器集成')),
			E('table', { 'class': 'table' }, integRows)
		]));

		/* Action section */
		var actionBtns = [];

		// Router config: setup or restore
		if (!integrated) {
			actionBtns.push(E('button', {
				'class': 'btn cbi-button cbi-button-apply',
				'click': ui.createHandlerFn(self, function() {
					if (!window.confirm(_('确认配置路由器吗？将创建网络接口并加入防火墙 wan 域。')))
						return Promise.resolve();
					return self.networkAction('setup');
				})
			}, _('一键配置')));
		} else {
			actionBtns.push(E('button', {
				'class': 'btn cbi-button cbi-button-reset',
				'click': ui.createHandlerFn(self, function() {
					if (!window.confirm(_('确认撤销配置吗？这将移除网络接口和防火墙配置，恢复原始状态。')))
						return Promise.resolve();
					return self.networkAction('restore');
				})
			}, _('撤销配置')));
		}

		// VoHive network: enable or disable based on connection state
		if (status.network_connected) {
			actionBtns.push(E('button', {
				'class': 'btn cbi-button cbi-button-reset',
				'click': ui.createHandlerFn(self, function() {
					return self.networkAction('disable');
				})
			}, _('禁用网络服务')));
		} else {
			actionBtns.push(E('button', {
				'class': 'btn cbi-button cbi-button-apply',
				'click': ui.createHandlerFn(self, function() {
					return self.networkAction('enable');
				})
			}, _('启用网络服务')));
		}

		actionBtns.push(E('button', {
			'class': 'btn cbi-button cbi-button-neutral',
			'click': ui.createHandlerFn(self, function() {
				return self.loadNetworkPane(self.networkPane);
			})
		}, _('刷新状态')));

		nodes.push(E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('操作')),
			E('div', { 'style': 'display:flex; gap:.5em; flex-wrap:wrap;' }, actionBtns),
			E('p', { 'style': 'margin-top:.75em; color:var(--text-color-medium); font-size:13px;' }, _(
				'启用后将自动创建不配置协议的网络接口并加入防火墙 wan 域，' +
				'使 4G/5G 数据连接获得 NAT 转发能力。' +
				'配置过程中 VoHive 数据连接会短暂中断并自动恢复。'
			))
		]));

		return E('div', {}, nodes);
	},

	networkAction: function(action, extraArgs) {
		var self = this;
		var script = '/usr/share/vohive/network_setup.sh';

		var actionLabel = action === 'setup' ? _('配置路由器') : action === 'restore' ? _('撤销配置') : action === 'enable' ? _('启用网络服务') : action === 'disable' ? _('禁用网络服务') : action === 'set_metric' ? _('设置路由优先级') : _('执行操作');

		ui.showModal(_('网络配置'), [
			E('div', { 'class': 'cbi-section' }, [
				E('em', { 'class': 'spinning' }, _('正在') + actionLabel + _('...'))
			])
		]);

		var args = [ action ];
		if (extraArgs)
			args = args.concat(extraArgs);

		return fs.exec_direct(script, args)
			.then(function(text) {
				ui.hideModal();
				var result = parseJson(text);
				notifyResult(text);
				return self.loadNetworkPane(self.networkPane);
			})
			.catch(function(e) {
				ui.hideModal();
				ui.addNotification(null, E('p', {}, e.message || String(e)), 'danger');
			});
	},

	loadNetworkPane: function(networkPane) {
		this.networkPane = networkPane;
		dom.content(networkPane, E('div', { 'class': 'cbi-section' },
			E('em', { 'class': 'spinning' }, _('正在读取网络状态...'))));

		var self = this;
		return this.loadNetworkStatus()
			.then(function(status) {
				dom.content(networkPane, self.renderNetworkContent(status));
			});
	},

	/* ---------------------------------------------------------- */
	/* 驱动管理 Tab                                               */
	/* ---------------------------------------------------------- */

	refreshDriverPane: function(driverPane, result) {
		return fs.exec_direct('/usr/share/vohive/usb_status.sh', [])
			.catch(function(e) {
				return JSON.stringify({ ok: false, message: e.message || String(e), devices: [], wwan_ifaces: [], cdc_devs: [] });
			})
			.then(function(text) {
				var data = parseJson(text);
				dom.content(driverPane, this.renderDriverContent(data, driverPane, result));
			}.bind(this));
	},

	runDriverBind: function(driverPane, args) {
		dom.content(driverPane, E('div', { 'class': 'cbi-section' },
			E('em', { 'class': 'spinning' }, _('正在执行操作...'))));

		return fs.exec_direct('/usr/share/vohive/driver_bind.sh', args)
			.catch(function(e) {
				return JSON.stringify({ ok: false, message: e.message || String(e) });
			})
			.then(function(text) {
				var result = parseJson(text);
				return this.refreshDriverPane(driverPane, result);
			}.bind(this));
	},

	renderDriverDeviceCard: function(dev, driverPane) {
		var self = this;
		var vid = dev.vid || '';
		var pid = dev.pid || '';
		var friendlyName = dev.friendly_name || dev.product || _('USB 设备');
		var vidpid = '%s:%s'.format(vid, pid);
		var ifaces = dev.interfaces || [];
		var moduleReady = dev.module_ready;
		var subtitle = [ dev.manufacturer, dev.product ].filter(Boolean).join('  ·  ');

		var netStatus;
		if (dev.net_iface && (dev.net_state === 'up' || dev.net_carrier === '1')) {
			netStatus = _('活跃（数据通路已建立）');
		} else if (dev.net_iface) {
			netStatus = _('就绪（驱动已绑定，接口已创建，等待拨号）');
		} else {
			netStatus = _('无（未绑定 QMI 驱动）');
		}

		var qmiCandidates = ifaces.filter(function(i) { return i.is_qmi_candidate; });

		var dataChannelNode;
		if (qmiCandidates.length === 0) {
			dataChannelNode = E('span', { 'style': 'color:var(--text-color-medium);' }, _('无可用数据通道'));
		} else {
			var select = E('select', { 'class': 'cbi-input-select', 'style': 'min-width:8em;' });
			qmiCandidates.forEach(function(i) {
				select.appendChild(E('option', {
					'value': i.iface,
					'selected': i.status === 'qmi' ? 'selected' : null
				}, i.iface));
			});

			var actionBtn = E('button', { 'class': 'btn cbi-button' });

			function updateActionButton() {
				var selectedIface = qmiCandidates.filter(function(i) { return i.iface === select.value; })[0];
				if (!selectedIface) {
					actionBtn.style.display = 'none';
					return;
				}
				actionBtn.style.display = '';
				if (selectedIface.status === 'qmi') {
					actionBtn.className = 'btn cbi-button cbi-button-reset';
					dom.content(actionBtn, _('解绑'));
					actionBtn.onclick = ui.createHandlerFn(self, function() {
						return self.runDriverBind(driverPane, [ 'unbind', selectedIface.iface ]);
					});
				} else {
					actionBtn.className = 'btn cbi-button cbi-button-apply';
					dom.content(actionBtn, _('绑定'));
					actionBtn.onclick = ui.createHandlerFn(self, function() {
						if (!window.confirm(_('确认将接口 %s 绑定到 QMI 数据通道吗？').format(selectedIface.iface)))
							return Promise.resolve();
						return self.runDriverBind(driverPane, [ 'bind_qmi', selectedIface.iface, vid, pid ]);
					});
				}
			}

			select.addEventListener('change', updateActionButton);
			updateActionButton();

			dataChannelNode = E('div', { 'style': 'display:flex; gap:.5em; align-items:center;' }, [
				select, actionBtn
			]);
		}

		var ifaceRows = ifaces.map(function(iface) {
			var deviceName = '';
			if (iface.status === 'qmi' && iface.usbmisc) {
				deviceName = iface.usbmisc;
			} else if (iface.tty_name) {
				deviceName = iface.tty_name;
			} else if (iface.net_iface) {
				deviceName = iface.net_iface;
			}
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td', 'style': 'font-family:monospace; white-space:nowrap;' }, iface.iface || '-'),
				E('td', { 'class': 'td' }, iface.status_label || '-'),
				E('td', { 'class': 'td', 'style': 'font-family:monospace;' }, deviceName || '-')
			]);
		});

		var moduleStatusNode = E('span', {
			'style': 'font-weight:700; color:%s;'.format(moduleReady ? '#37a24d' : '#3b82f6')
		}, moduleReady ? _('已就绪') : _('空闲'));

		var children = [
			E('div', {
				'style': 'display:flex; align-items:flex-start; justify-content:space-between; gap:1em; flex-wrap:wrap; margin-bottom:.75em;'
			}, [
				E('div', {}, [
					E('h4', { 'style': 'margin:0 0 .2em 0;' }, '%s（%s）'.format(friendlyName, vidpid)),
					subtitle ? E('div', { 'style': 'color:var(--text-color-medium); font-size:13px;' }, subtitle) : ''
				])
			]),
			this.renderInfoGrid([
				[ _('模块状态'), moduleStatusNode ],
				[ _('网络接口'), netStatus ],
				[ _('数据通道'), dataChannelNode ]
			])
		];

		if (ifaceRows.length) {
			children.push(E('table', { 'class': 'table', 'style': 'margin-top:.75em;' }, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th' }, _('接口')),
					E('th', { 'class': 'th' }, _('类型')),
					E('th', { 'class': 'th' }, _('设备'))
				])
			].concat(ifaceRows)));
		}

		return E('div', {
			'class': 'cbi-section',
			'style': 'border-left:4px solid %s;'.format(moduleReady ? '#37a24d' : '#3b82f6')
		}, children);
	},

	renderDriverContent: function(data, driverPane, result) {
		var nodes = [];

		if (result)
			nodes.push(E('div', { 'class': 'alert-message %s'.format(result.ok === false ? 'danger' : 'success') }, [
				E('p', {}, result.message || (result.ok === false ? _('操作失败') : _('操作完成')))
			]));

		if (data.ok === false) {
			nodes.push(E('div', { 'class': 'alert-message danger' },
				_('读取 USB 状态失败：%s').format(data.message || _('未知错误'))));
			return E('div', {}, nodes);
		}

		var devices = data.devices || [];
		var readyCount = devices.filter(function(d) { return d.module_ready; }).length;

		var summaryText;
		if (devices.length === 0) {
			summaryText = _('未检测到通信模块');
		} else {
			summaryText = _('%d 个模块，%d 个已就绪').format(devices.length, readyCount);
		}

		nodes.push(E('div', { 'class': 'cbi-section' }, [
			E('h3', { 'style': 'margin-bottom:.5em;' }, _('驱动管理')),
			E('p', {
				'style': 'font-weight:700; color:%s;'.format(readyCount > 0 ? '#37a24d' : '#d9534f')
			}, summaryText)
		]));

		devices.forEach(function(dev) {
			nodes.push(this.renderDriverDeviceCard(dev, driverPane));
		}.bind(this));

		return E('div', {}, nodes);
	},

	loadDriverPane: function(driverPane) {
		dom.content(driverPane, E('div', { 'class': 'cbi-section' },
			E('em', { 'class': 'spinning' }, _('正在读取 USB 驱动状态...'))));
		return this.refreshDriverPane(driverPane);
	},

	/* ---------------------------------------------------------- */
	/* 基础配置 / 日志                                            */
	/* ---------------------------------------------------------- */

	renderConfigMap: function() {
		var m = new form.Map('vohive');
		var s, o;

		s = m.section(form.NamedSection, 'main', 'vohive', _('基础配置'));
		s.addremove = false;

		o = s.option(form.Flag, 'enabled', _('启用服务'));
		o.default = '0';

		o = s.option(form.Value, 'host', _('监听地址'));
		o.default = '0.0.0.0';

		o = s.option(form.Value, 'port', _('监听端口'));
		o.default = '7575';
		o.datatype = 'port';

		o = s.option(form.Value, 'username', _('Web 用户名'));
		o.default = 'admin';
		o.rmempty = false;

		o = s.option(form.Value, 'password', _('Web 密码'));
		o.default = 'admin';
		o.password = true;
		o.rmempty = false;

		o = s.option(form.ListValue, 'log_level', _('日志级别'));
		o.value('debug', 'debug');
		o.value('info', 'info');
		o.value('warn', 'warn');
		o.value('error', 'error');
		o.default = 'info';

		o = s.option(form.Value, 'data_path', _('数据目录'));
		o.default = '/etc/vohive/data';
		o.validate = function(section_id, value) {
			return /^\/.+/.test(value) || _('必须是绝对路径');
		};

		o = s.option(form.Button, '_apply_config', _('保存并应用'));
		o.inputstyle = 'apply';
		o.onclick = ui.createHandlerFn(this, function() {
			return saveApplyThen(m, function() {
				return runScript('/usr/share/vohive/apply_config.sh', []);
			});
		});

		return m.render().then(function(node) {
			node.querySelectorAll('input[id$=".username"]').forEach(function(input) {
				input.setAttribute('autocomplete', 'off');
			});
			node.querySelectorAll('input[id$=".password"]').forEach(function(input) {
				input.setAttribute('autocomplete', 'new-password');
			});
			return node;
		});
	},

	renderStatus: function(status, releases, plugin) {
		var webUrl = 'http://%s:%s'.format(window.location.hostname, status.port || '7575');
		var listenAddress = '%s:%s'.format(status.host || '0.0.0.0', status.port || '7575');
		if (status.port_status && status.port_status !== 'unknown')
			listenAddress = '%s (%s)'.format(listenAddress, status.port_status);

		var releaseRepo = releaseRepoSlug(uci.get('vohive', 'main', 'release_repo'));
		var pluginRepo = DEFAULT_PLUGIN_REPO;
		var coreVersion = status.core_installed ? (status.core_version || _('已安装')) : _('未安装');
		var pluginVersion = status.plugin_version || _('未知');

		var coreLatest = '';
		if (releases && releases.latest) {
			var canUpdate = status.core_installed && status.core_version && status.core_version != releases.latest;
			coreLatest = E('span', {}, [
				releaseLink(releaseRepo, releases.latest),
				' ',
				E('span', { 'style': 'color:%s;'.format(canUpdate ? '#d58512' : '#37a24d') }, canUpdate ? _('(可更新)') : _('(已是最新)'))
			]);
		} else if (releases && releases.loading) {
			coreLatest = loadingText(_('正在加载...'));
		} else {
			coreLatest = _('未知');
		}

		var pluginLatest = '';
		if (plugin && plugin.latest && plugin.ok !== false) {
			var pluginCanUpdate = plugin.has_update;
			pluginLatest = E('span', {}, [
				pluginVersionLink(pluginRepo, plugin.latest),
				' ',
				E('span', { 'style': 'color:%s;'.format(pluginCanUpdate ? '#d58512' : '#37a24d') }, pluginCanUpdate ? _('(可更新)') : _('(已是最新)'))
			]);
		} else if (plugin && plugin.loading) {
			pluginLatest = loadingText(_('正在加载...'));
		} else {
			pluginLatest = _('未知');
		}

		var rows = [
			[ _('服务状态'), statusBadge(status.running) ],
			[ _('数据连接'), status.running ? E('span', {
				'style': 'color:%s; font-weight:700;'.format(status.data_connected ? '#37a24d' : '#d9534f')
			}, status.data_connected ? _('已连接') : _('未连接')) : _('未运行') ],
			[ _('核心版本'), E('span', {}, [ coreVersion, ' ', E('span', { 'style': 'color:var(--text-color-medium);' }, _('最新: ')), coreLatest ]) ],
			[ _('插件版本'), E('span', {}, [ pluginVersionLink(pluginRepo, pluginVersion), ' ', E('span', { 'style': 'color:var(--text-color-medium);' }, _('最新: ')), pluginLatest ]) ],
			[ _('监听地址'), status.running ? E('a', { 'href': webUrl, 'target': '_blank' }, listenAddress) : listenAddress ],
			[ _('CPU / 内存占用'), status.running ? cpuMemoryText(status) : _('未运行') ],
		];

		var sameMount = status.root_mount && status.data_mount && status.root_mount === status.data_mount;
		if (sameMount) {
			rows.push([ _('磁盘空间'), progressbar(status.root_used_kb, status.root_total_kb, status.root_percent) ]);
		} else {
			rows.push([ _('根分区空间'), progressbar(status.root_used_kb, status.root_total_kb, status.root_percent) ]);
			rows.push([ _('数据目录空间'), progressbar(status.data_used_kb, status.data_total_kb, status.data_percent) ]);
		}

		var table = E('table', { 'class': 'table' }, rows.map(function(row) {
			return E('tr', {}, [ E('td', {}, row[0]), E('td', {}, row[1]) ]);
		}));

		var warnings = [];
		if (status.default_password)
			warnings.push(E('div', { 'class': 'alert-message warning', 'style': 'margin-top:.75em;' }, _('LuCI 配置中仍使用默认 Web 密码 admin/admin，请在"基础配置"中修改。')));
		if (!status.core_installed)
			warnings.push(E('div', { 'class': 'alert-message warning', 'style': 'margin-top:.5em;' }, _('VoHive 核心尚未安装。')));

		return E('div', { 'class': 'cbi-section' }, [
			E('div', {
				'style': 'display:flex; align-items:center; justify-content:space-between; gap:1em; flex-wrap:wrap;'
			}, [
				E('h3', { 'style': 'margin-bottom:.75em;' }, _('运行状态'))
			]),
			table
		].concat(warnings).concat([
			E('div', { 'style': 'display:flex; align-items:center; justify-content:space-between; margin-top:.75em; flex-wrap:wrap; gap:1em;' }, [
				this.renderServiceButtons(),
				status.running ? E('a', { 'class': 'btn cbi-button cbi-button-action', 'target': '_blank', 'href': webUrl }, _('打开 VoHive Web UI')) : ''
			])
		]));
	},

updateStatusNode: function(status) {
	if (!this.statusNode)
		return;

	dom.content(this.statusNode, this.renderStatus(status, this.releasesData, this.pluginData));
},

	refreshStatus: function() {
		return fs.exec_direct('/usr/share/vohive/status.sh', [])
			.catch(function() { return '{}'; })
			.then(function(text) {
				var status = parseJson(text);
				this.updateStatusNode(status);
				return status;
			}.bind(this));
	},

	renderServiceButtons: function() {
		return E('span', {}, [
			E('button', {
				'class': 'btn cbi-button cbi-button-apply',
				'click': ui.createHandlerFn(this, function() { return runScript('/usr/share/vohive/service.sh', [ 'start' ]); })
			}, _('启动')),
			' ',
			E('button', {
				'class': 'btn cbi-button cbi-button-reset',
				'click': ui.createHandlerFn(this, function() { return runScript('/usr/share/vohive/service.sh', [ 'stop' ]); })
			}, _('停止')),
			' ',
			E('button', {
				'class': 'btn cbi-button cbi-button-reload',
				'click': ui.createHandlerFn(this, function() { return runScript('/usr/share/vohive/service.sh', [ 'restart' ]); })
			}, _('重启')),
			' ',
			E('button', {
				'class': 'btn cbi-button cbi-button-reset',
				'style': 'background:#f0ad4e; border-color:#f0ad4e; color:#fff;',
				'click': ui.createHandlerFn(this, function() {
					if (!window.confirm(_('将重置模组并恢复 QMI 通信，期间服务会短暂中断，是否继续？')))
						return Promise.resolve();
					return runScript('/usr/share/vohive/recover_qmi.sh', []);
				})
			}, _('修复'))
		]);
	},

	refreshLogs: function(logNode) {
		return fs.exec_direct('/usr/share/vohive/logs.sh', [ '100' ])
			.catch(function() { return ''; })
			.then(function(logs) {
				this.currentLogs = logs || '';
				dom.content(logNode, this.currentLogs || _('暂无日志'));
			}.bind(this));
	},

	setLogAutoRefresh: function(enabled, logNode) {
		if (this.logRefreshTimer) {
			window.clearInterval(this.logRefreshTimer);
			this.logRefreshTimer = null;
		}

		if (enabled) {
			this.refreshLogs(logNode);
			this.logRefreshTimer = window.setInterval(function() {
				this.refreshLogs(logNode);
			}.bind(this), 5000);
		}
	},

	clearLogs: function(logNode) {
		return fs.exec_direct('/usr/share/vohive/clear_logs.sh', [])
			.then(function(text) {
				notifyResult(text);
				return this.refreshLogs(logNode);
			}.bind(this))
			.catch(function(e) {
				ui.addNotification(null, E('p', {}, e.message || String(e)), 'danger');
			});
	},

	downloadLogs: function() {
		var blob = new Blob([ this.currentLogs || '' ], { type: 'text/plain;charset=utf-8' });
		var url = URL.createObjectURL(blob);
		var a = E('a', {
			'href': url,
			'download': 'vohive-logs.txt'
		});

		document.body.appendChild(a);
		a.click();
		document.body.removeChild(a);
		window.setTimeout(function() { URL.revokeObjectURL(url); }, 1000);
	},

	renderLogs: function(logs) {
		this.currentLogs = logs || '';
		var logNode = E('pre', {
			'style': [
				'white-space: pre',
				'height: 460px',
				'overflow: auto',
				'margin: 0',
				'padding: 1em',
				'border: 1px solid var(--border-color-medium)',
				'border-radius: 6px',
				'background: var(--background-color-low)',
				'font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace',
				'font-size: 12px',
				'line-height: 1.55'
			].join(';')
		}, this.currentLogs || _('暂无日志'));

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('运行日志')),
			E('div', {
				'style': [
					'display: flex',
					'align-items: center',
					'justify-content: space-between',
					'gap: 1em',
					'flex-wrap: wrap',
					'margin-bottom: 1em'
				].join(';')
			}, [
				E('label', {
					'style': 'display: inline-flex; align-items: center; gap: .5em; margin: 0;'
				}, [
					E('input', {
						'type': 'checkbox',
						'style': 'margin: 0;',
						'change': function(ev) {
							this.setLogAutoRefresh(ev.target.checked, logNode);
						}.bind(this)
					}),
					E('span', {}, _('自动刷新'))
				]),
				E('div', { 'style': 'display: flex; gap: .5em; flex-wrap: wrap;' }, [
					E('button', {
						'class': 'btn cbi-button cbi-button-reload',
						'click': ui.createHandlerFn(this, function() { return this.refreshLogs(logNode); })
					}, _('刷新')),
					E('button', {
						'class': 'btn cbi-button cbi-button-reset',
						'click': ui.createHandlerFn(this, function() { return this.clearLogs(logNode); })
					}, _('清理日志')),
					E('button', {
						'class': 'btn cbi-button cbi-button-action',
						'click': ui.createHandlerFn(this, function() { this.downloadLogs(); })
					}, _('下载日志'))
				])
			]),
			logNode
		]);
	},

	render: function(data) {
		var status = parseJson(data[1]);
		var logs = data[2] || '';
		var releases = parseJson(data[3]);
		var plugin = parseJson(data[4]);
		var deviceDeps = parseJson(data[5]);

		if (!releases.repo)
			releases.repo = releaseRepoSlug(uci.get('vohive', 'main', 'release_repo'));
		if (!releases.versions)
			releases.versions = [];

		return Promise.all([
			this.renderConfigMap()
		]).then(function(rendered) {
			poll.add(this.refreshStatus.bind(this), 5);

			var driverPane = E('div', { 'data-tab': 'driver', 'data-tab-title': _('驱动管理') }, [
				E('div', { 'class': 'cbi-section' }, E('em', {}, _('点击驱动管理后读取 USB 驱动状态。')))
			]);
			this.driverPane = driverPane;

			driverPane.addEventListener('cbi-tab-active', function() {
				this.loadDriverPane(driverPane);
			}.bind(this));

			var devicePane = E('div', { 'data-tab': 'device', 'data-tab-title': _('设备管理') }, [
				E('div', { 'class': 'cbi-section' }, E('em', {}, _('点击设备管理后探测串口设备。')))
			]);
			this.devicePane = devicePane;

			devicePane.addEventListener('cbi-tab-active', function() {
				if (devicePane.getAttribute('data-loaded') !== 'true' && devicePane.getAttribute('data-loading') !== 'true')
					this.loadDevicePane(devicePane);
			}.bind(this));

			var self = this;

			return this.renderOverview(status, releases, plugin, deviceDeps).then(function(overviewEl) {
				var networkPane = E('div', { 'data-tab': 'network', 'data-tab-title': _('网络管理') }, [
					E('div', { 'class': 'cbi-section' }, E('em', {}, _('点击网络管理后读取连接状态。')))
				]);
				self.networkPane = networkPane;

				networkPane.addEventListener('cbi-tab-active', function() {
					self.loadNetworkPane(networkPane);
				});

				var panes = E('div', {}, [
					E('div', { 'data-tab': 'overview', 'data-tab-title': _('概览') }, overviewEl),
					networkPane,
					driverPane,
					devicePane,
					E('div', { 'data-tab': 'config', 'data-tab-title': _('基础配置') }, rendered[0]),
					E('div', { 'data-tab': 'logs', 'data-tab-title': _('日志') }, self.renderLogs(logs))
				]);
				var tabs = E('div', {}, panes);

				ui.tabs.initTabGroup(panes.childNodes);
				window.setTimeout(self.restoreRunningTask.bind(self), 0);

				return E('div', {}, [
					E('div', { 'class': 'cbi-map-descr' }, [
						_('VoHive 的 OpenWrt 管理插件，在路由器界面中完成核心安装、服务控制、配置管理与 USB 驱动运维。'),
						E('br'),
						_('仓库地址：'),
				E('a', { 'href': 'https://github.com/voorz/luci-app-vohive', 'target': '_blank' }, _('点击访问'))
			]),
					tabs
				]);
			});
		}.bind(this));
	}
});
