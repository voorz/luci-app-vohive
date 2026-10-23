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

function confirmModal(title, message) {
	return new Promise(function(resolve) {
		ui.showModal(title, [
			E('div', { 'class': 'cbi-section' }, [
				E('p', {}, message),
				E('div', { 'style': 'text-align:right; margin-top:1em;' }, [
					E('button', {
						'class': 'btn cbi-button cbi-button-neutral',
						'click': function() { ui.hideModal(); resolve(false); }
					}, _('取消')),
					' ',
					E('button', {
						'class': 'btn cbi-button cbi-button-apply',
						'click': function() { ui.hideModal(); resolve(true); }
					}, _('确认'))
				])
			])
		]);
	});
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

var DEFAULT_CORE_REPO = 'https://github.com/voorz/vohive-release';
var DEFAULT_PLUGIN_REPO = 'voorz/luci-app-vohive';

function releaseRepoSlug(repo) {
	/* GitHub repo addresses are owner/repo: keep the first two path
	   segments and drop any trailing ones (e.g. /releases). */
	return (repo || DEFAULT_CORE_REPO)
		.replace(/^https?:\/\/github\.com\//, '')
		.replace(/^git@github\.com:/, '')
		.split('/')
		.filter(function(part) { return part !== ''; })
		.slice(0, 2)
		.join('/')
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
	pluginSectionNode: null,
	releasesData: null,
	taskTimer: null,
	taskModalBody: null,
	activeTaskId: null,
	activeTaskType: null,
	taskCompletedHandled: false,

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
			fs.exec_direct('/usr/share/vohive/releases.sh', [ '5', 'cached' ]).catch(function() { return '{"ok":false,"versions":[]}'; }),
			fs.exec_direct('/usr/share/vohive/plugin_status.sh', [ '5', 'cached' ]).catch(function() { return '{"ok":false}'; })
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

	refreshPluginSection: function() {
		if (!this.pluginSectionNode)
			return Promise.resolve();

		dom.content(this.pluginSectionNode, this.renderPluginManagement(this.pluginData || {}));
		return Promise.resolve();
	},

	checkVersionUpdates: function(ev) {
		var btn = ev && ev.target && ev.target.closest ? ev.target.closest('button') : null;
		if (btn) {
			btn.disabled = true;
			dom.content(btn, E('em', { 'class': 'spinning' }, ''));
		}
		this.checkingVersions = true;

		var self = this;
		return Promise.all([
			fs.exec_direct('/usr/share/vohive/releases.sh', [ '5', 'force' ]).catch(function() { return '{"ok":false,"versions":[]}'; }),
			fs.exec_direct('/usr/share/vohive/plugin_status.sh', [ '5', 'force' ]).catch(function() { return '{"ok":false}'; })
		]).then(function(res) {
			self.releasesData = parseJson(res[0]);
			if (!self.releasesData.repo)
				self.releasesData.repo = releaseRepoSlug(uci.get('vohive', 'main', 'release_repo'));
			if (!self.releasesData.versions)
				self.releasesData.versions = [];
			self.pluginData = parseJson(res[1]);
			self.checkingVersions = false;
			return self.refreshStatus();
		}).then(function(fresh) {
			return Promise.all([
				self.refreshCoreSection(fresh || {}),
				self.refreshPluginSection()
			]);
		}).catch(function() {
			self.checkingVersions = false;
			return self.refreshStatus();
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

	renderOverview: function(status, releases, plugin) {
		var self = this;

		this.statusNode = E('div', {}, this.renderStatus(status, releases, plugin));
		this.releasesData = releases;
		this.pluginData = plugin;
		this.lastStatus = status;

		this.configFieldsNode = E('div', {}, this.renderConfigFields());
		this.actionRowNode = E('div', {}, this.renderActionRow(status));
		this.coreSectionNode = E('div', {});

		return this.renderCoreManagement(status, releases).then(function(coreEl) {
			dom.content(self.coreSectionNode, coreEl);

			return E('div', { 'class': 'cbi-section' }, [
				E('div', { 'style': 'display:flex; gap:2em; flex-wrap:wrap;' }, [
					E('div', { 'style': 'flex:1 1 320px; min-width:260px;' }, self.statusNode),
					E('div', { 'style': 'flex:1 1 320px; min-width:260px;' }, [
						E('div', {
							'style': 'display:flex; align-items:center; justify-content:space-between; gap:1em; flex-wrap:wrap;'
						}, [
							E('h3', { 'style': 'margin-bottom:.75em;' }, _('基础配置'))
						]),
						self.configFieldsNode
					])
				]),
				self.actionRowNode
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
		o.rmempty = false;
		o.default = DEFAULT_CORE_REPO;
		o.validate = function(section_id, value) {
			return /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(releaseRepoSlug(value)) || _('必须是 GitHub 仓库地址');
		};

		o = s.option(form.DummyValue, '_repo_status', _('仓库状态'));
		o.rawhtml = true;
		o.cfgvalue = function(section_id) {
			var color = repoOk ? '#37a24d' : '#d9534f';
			var text = repoOk ? _('可用') : _('不可用或无 Release');
			var repo = releaseRepoSlug(uci.get('vohive', section_id, 'release_repo'));
			return '<span style="color:%s; font-weight:700;">●</span> <span style="color:%s;">%s</span> <a href="https://github.com/%s/releases" target="_blank" rel="noreferrer" style="margin-left:1em;">前往核心发布页↗</a>'.format(color, color, text, repo);
		};

		o = s.option(form.ListValue, 'core_arch', _('核心架构'));
		o.rmempty = false;
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
		o.rmempty = false;
		(releases.versions || []).forEach(function(version) {
			o.value(version, version);
		});
		o.default = (releases.versions || [])[0];
		o.cfgvalue = function(section_id) {
			var value = uci.get('vohive', section_id, 'version');
			return (value && (releases.versions || []).indexOf(value) >= 0) ? value : (releases.versions || [])[0];
		};
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

	renderPluginManagement: function(plugin) {
		var depRows = [
			{ name: 'kmod-usb-serial', installed: plugin.serial_driver_installed },
			{ name: 'kmod-usb-serial-option', installed: plugin.option_driver_installed }
		].map(function(dep) {
			var status;
			if (dep.installed) {
				status = E('span', { 'style': 'color:#37a24d; font-weight:700;' }, _('已安装'));
			} else {
				status = E('button', {
					'class': 'btn cbi-button cbi-button-action',
					'click': function() {
						return runScript('/usr/share/vohive/install_deps.sh', [ 'install_serial_drivers' ]);
					}
				}, _('安装依赖'));
			}
			return E('tr', {}, [ E('td', { 'style': 'width:30%;' }, dep.name), E('td', {}, status) ]);
		});

		var tableRows = depRows;

		var nodes = [
			E('div', { 'class': 'cbi-section' }, [
				E('h3', { 'style': 'margin-bottom:.75em;' }, _('插件与依赖')),
				E('table', { 'class': 'table' }, tableRows)
			])
		];

		if (plugin.ok === false && !plugin.loading)
			nodes.unshift(E('div', { 'class': 'alert-message warning' }, plugin.message || _('无法获取插件版本信息。')));

		return E('div', {}, nodes);
	},

	/* ---------------------------------------------------------- */
	/* 网络配置 Tab                                               */
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

		var netConfigured = status.netifd_configured;
		var fwConfigured = status.firewall_configured;
		var integrated = netConfigured && fwConfigured;

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
			integRows.push(E('tr', {}, [
				E('td', {}, _('模块主力')),
				E('td', {}, E('span', {
					'style': 'color:%s; font-weight:700;'.format(status.is_primary ? '#37a24d' : '#d58512')
				}, status.is_primary ? _('是') : _('否')))
			]));
		}

		if (integrated) {
			var isPrimary = status.is_primary;

			/* Find cellular metric from default routes (QMI hardcoded, usually 5000) */
			var cellularMetric = 5000;
			if (status.default_routes && status.wwan_iface) {
				for (var i = 0; i < status.default_routes.length; i++) {
					if (status.default_routes[i].dev === status.wwan_iface) {
						cellularMetric = status.default_routes[i].metric;
						break;
					}
				}
			}

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

			var customHint = E('span', {
				'style': 'font-size:12px; color:var(--text-color-medium); display:none; margin-left:.25em;'
			}, _('模块跃点 %s，填 < %s 为备用，> %s 为主力').format(cellularMetric, cellularMetric, cellularMetric));

			var customInput = E('input', {
				'type': 'number', 'min': '0', 'max': '65535',
				'class': 'cbi-input-text',
				'style': 'width:6em; display:none;',
				'placeholder': 'metric'
			});

			metricSelect.addEventListener('change', function(ev) {
				var isCustom = (ev.target.value === 'custom');
				customInput.style.display = isCustom ? 'inline-block' : 'none';
				customHint.style.display = isCustom ? 'inline' : 'none';
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
					return confirmModal(_('路由优先级'), _('确认将路由优先级设为 %s 吗？').format(label))
						.then(function(ok) { return ok ? self.networkAction('set_metric', [ mode ]) : Promise.resolve(); });
				})
			}, _('应用'));

			integRows.push(E('tr', {}, [
				E('td', {}, _('路由优先级')),
				E('td', { 'style': 'white-space:nowrap;' }, [ metricSelect, ' ', customInput, ' ', applyBtn, ' ', customHint ])
			]));
		} else {
			integRows.push(E('tr', {}, [
				E('td', {}, _('路由优先级')),
				E('td', {}, E('span', {
					'style': 'color:%s; font-weight:700;'.format(status.is_primary ? '#37a24d' : '#d58512')
				}, status.is_primary ? _('主力（4G/5G 优先）') : _('备用（其他 WAN 优先）')))
			]));
		}

		/* Actions live inside the integration section */
		var actionBtns = [];

		// Router config: setup or restore
		if (!integrated) {
			actionBtns.push(E('button', {
				'class': 'btn cbi-button cbi-button-apply',
				'click': ui.createHandlerFn(self, function() {
					return confirmModal(_('网络配置'), _('确认配置路由器吗？将创建网络接口并加入防火墙 wan 域。'))
						.then(function(ok) { return ok ? self.networkAction('setup') : Promise.resolve(); });
				})
			}, _('一键配置')));
		} else {
			actionBtns.push(E('button', {
				'class': 'btn cbi-button cbi-button-reset',
				'click': ui.createHandlerFn(self, function() {
					return confirmModal(_('网络配置'), _('确认撤销配置吗？这将移除网络接口和防火墙配置，恢复原始状态。'))
						.then(function(ok) { return ok ? self.networkAction('restore') : Promise.resolve(); });
				})
			}, _('撤销配置')));
		}

		actionBtns.push(E('button', {
			'class': 'btn cbi-button cbi-button-neutral',
			'click': ui.createHandlerFn(self, function() {
				return self.loadNetworkPane(self.networkPane);
			})
		}, _('刷新状态')));

		nodes.push(E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('路由器集成')),
			E('table', { 'class': 'table' }, integRows),
			E('div', { 'style': 'display:flex; gap:.5em; flex-wrap:wrap; margin-top:.75em;' }, actionBtns),
			E('p', { 'style': 'margin-top:.75em; color:var(--text-color-medium); font-size:13px;' }, _(
				'创建网络接口并加入防火墙 wan 域，提供 NAT 转发；联网由核心管理。'
			))
		]));

		return E('div', {}, nodes);
	},

	networkAction: function(action, extraArgs) {
		var self = this;
		var script = '/usr/share/vohive/network_setup.sh';

		var actionLabel = action === 'setup' ? _('配置路由器') : action === 'restore' ? _('撤销配置') : action === 'set_metric' ? _('设置路由优先级') : _('执行操作');

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
				var result = parseJson(text);
				if (result.ok === false) {
					ui.showModal(actionLabel + _('失败'), [
						E('div', { 'class': 'cbi-section' }, [
							E('p', { 'style': 'color:#d9534f; font-weight:700;' }, result.message || _('操作失败')),
							E('div', { 'style': 'text-align:right; margin-top:1em;' }, [
								E('button', {
									'class': 'btn cbi-button cbi-button-neutral',
									'click': ui.createHandlerFn(self, function() {
										ui.hideModal();
										return self.loadNetworkPane(self.networkPane);
									})
								}, _('确定'))
							])
						])
					]);
					return;
				}
				ui.hideModal();
				return self.loadNetworkPane(self.networkPane);
			})
			.catch(function(e) {
				ui.showModal(actionLabel + _('失败'), [
					E('div', { 'class': 'cbi-section' }, [
						E('p', { 'style': 'color:#d9534f; font-weight:700;' }, e.message || String(e)),
						E('div', { 'style': 'text-align:right; margin-top:1em;' }, [
							E('button', {
								'class': 'btn cbi-button cbi-button-neutral',
								'click': ui.createHandlerFn(self, function() {
									ui.hideModal();
									return self.loadNetworkPane(self.networkPane);
								})
							}, _('确定'))
						])
					])
				]);
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
	/* 基础配置 / 日志                                            */
	/* ---------------------------------------------------------- */

	renderConfigFields: function() {
		var inputStyle = 'width:100%; box-sizing:border-box;';
		var field = function(label, input) {
			return E('div', { 'style': 'margin-bottom:.8em;' }, [
				E('label', { 'style': 'display:block; font-weight:600; margin-bottom:.3em;' }, label),
				input
			]);
		};
		var level = uci.get('vohive', 'main', 'log_level') || 'debug';

		return [
			field(_('监听端口'), E('input', {
				'type': 'number', 'min': '1', 'max': '65535', 'style': inputStyle,
				'data-opt': 'port', 'value': uci.get('vohive', 'main', 'port') || '7575'
			})),
			field(_('Web 用户名'), E('input', {
				'type': 'text', 'style': inputStyle, 'autocomplete': 'off',
				'data-opt': 'username', 'value': uci.get('vohive', 'main', 'username') || 'admin'
			})),
			field(_('登录凭据'), E('input', {
				'type': 'text', 'style': inputStyle, 'autocomplete': 'off',
				'data-opt': 'password', 'value': uci.get('vohive', 'main', 'password') || 'admin'
			})),
			field(_('日志级别'), E('select', {
				'style': inputStyle, 'data-opt': 'log_level'
			}, [ 'debug', 'info', 'warn', 'error' ].map(function(l) {
				return E('option', { 'value': l, 'selected': (l === level) ? '' : null }, l);
			}))),
			field(_('数据目录'), E('input', {
				'type': 'text', 'style': inputStyle,
				'data-opt': 'data_path', 'value': uci.get('vohive', 'main', 'data_path') || '/etc/vohive/data'
			}))
		];
	},

	renderActionRow: function(status) {
		var running = !!status.running;
		var toggleColor = running ? '#d9534f' : '#37a24d';

		var children = [
			E('button', {
				'class': 'btn cbi-button',
				'style': 'color:#fff; background:%s; border-color:%s;'.format(toggleColor, toggleColor),
				'click': ui.createHandlerFn(this, function() { return this.toggleService(running); })
			}, running ? _('停止') : _('启动')),
			E('button', {
				'class': 'btn cbi-button cbi-button-apply',
				'title': _('重新应用新的更改并重启vohive核心'),
				'click': ui.createHandlerFn(this, function() { return this.applyConfigFields(); })
			}, _('重载'))
		];

		if (running) {
			children.push(E('button', {
				'class': 'btn cbi-button cbi-button-apply',
				'data-url': 'http://' + window.location.hostname + ':' + (status.port || 7575) + '/',
				'click': function(ev) { window.open(ev.currentTarget.getAttribute('data-url'), '_blank'); }
			}, _('打开 VoHive Web UI')));
		}

		return E('div', { 'style': 'margin-top:1em; display:flex; gap:.5em; flex-wrap:wrap; align-items:center;' }, children);
	},

	toggleService: function(running) {
		return runScript('/usr/share/vohive/service.sh', [ running ? 'stop' : 'start' ]);
	},

	applyConfigFields: function() {
		var values = {};

		this.configFieldsNode.querySelectorAll('[data-opt]').forEach(function(input) {
			values[input.getAttribute('data-opt')] = input.value;
		});

		var port = parseInt(values.port, 10);
		if (!(port >= 1 && port <= 65535)) {
			ui.addNotification(null, E('p', {}, _('监听端口必须是 1-65535 之间的数字')), 'danger');
			return Promise.resolve();
		}
		if (!/^\/.+/.test(values.data_path || '')) {
			ui.addNotification(null, E('p', {}, _('数据目录必须是绝对路径')), 'danger');
			return Promise.resolve();
		}

		Object.keys(values).forEach(function(key) {
			uci.set('vohive', 'main', key, values[key]);
		});

		return uci.save().then(function() {
			return runScript('/usr/share/vohive/apply_config.sh', []);
		});
	},

	renderStatus: function(status, releases, plugin) {
		var releaseRepo = releaseRepoSlug(uci.get('vohive', 'main', 'release_repo'));
		var pluginRepo = DEFAULT_PLUGIN_REPO;
		var coreVersion = status.core_installed ? (status.core_version || _('已安装')) : _('未安装');
		var pluginVersion = status.plugin_version || _('未知');
		var pluginVersionText = /^[0-9]/.test(pluginVersion) ? 'v' + pluginVersion : pluginVersion;

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

		var checkIcon = E('span', { 'style': 'display:inline-block; width:15px; height:15px; vertical-align:-2px;' });
		checkIcon.innerHTML = '<svg viewBox="0 0 24 24" width="15" height="15" style="display:block" aria-hidden="true"><path fill="currentColor" d="M17.65 6.35A7.958 7.958 0 0 0 12 4c-4.42 0-7.99 3.58-7.99 8s3.57 8 7.99 8c3.73 0 6.84-2.55 7.73-6h-2.08A5.99 5.99 0 0 1 12 18c-3.31 0-6-2.69-6-6s2.69-6 6-6c1.66 0 3.14.69 4.22 1.78L13 11h7V4l-2.35 2.35z"/></svg>';

		var rows = [
			[ _('服务状态'), statusBadge(status.running) ],
			[ _('核心版本'), E('span', {}, [ coreVersion, ' ', E('span', { 'style': 'color:var(--text-color-medium);' }, _('最新: ')), coreLatest ]) ],
			[ _('插件版本'), E('span', {}, [ pluginVersionText, ' ', E('span', { 'style': 'color:var(--text-color-medium);' }, _('最新: ')), pluginLatest, ' ', E('button', {
				'class': 'vohive-check-btn',
				'title': _('检查更新'),
				'style': 'background:none; border:none; box-shadow:none; padding:2px 6px; margin:0; cursor:pointer; color:inherit; font:inherit; vertical-align:middle;',
				'disabled': this.checkingVersions ? true : null,
				'click': ui.createHandlerFn(this, this.checkVersionUpdates)
			}, this.checkingVersions ? E('em', { 'class': 'spinning' }, '') : checkIcon), ' ', E('button', {
				'class': 'btn cbi-button cbi-button-action',
				'disabled': (plugin && plugin.ok !== false && !plugin.has_update) ? true : null,
				'click': ui.createHandlerFn(this, function() {
					return this.startTask('update_plugin', []);
				})
			}, (plugin && plugin.ok !== false && !plugin.has_update) ? _('无需更新') : _('更新 LuCI 插件')) ]) ],
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
		if (!status.core_installed)
			warnings.push(E('div', { 'class': 'alert-message warning', 'style': 'margin-top:.5em;' }, _('VoHive 核心尚未安装。')));

		return [
			E('div', {
				'style': 'display:flex; align-items:center; justify-content:space-between; gap:1em; flex-wrap:wrap;'
			}, [
				E('h3', { 'style': 'margin-bottom:.75em;' }, _('运行状态'))
			]),
			table
		].concat(warnings);
	},

updateStatusNode: function(status) {
	if (!this.statusNode)
		return;

	this.lastStatus = status;
	dom.content(this.statusNode, this.renderStatus(status, this.releasesData, this.pluginData));
	if (this.actionRowNode)
		dom.content(this.actionRowNode, this.renderActionRow(status));
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

		if (!releases.repo)
			releases.repo = releaseRepoSlug(uci.get('vohive', 'main', 'release_repo'));
		if (!releases.versions)
			releases.versions = [];

		return Promise.all([
			Promise.resolve(null)
		]).then(function() {
			poll.add(this.refreshStatus.bind(this), 5);

			var self = this;

			return this.renderOverview(status, releases, plugin).then(function(overviewEl) {
				var networkPane = E('div', {}, [
					E('div', { 'class': 'cbi-section' }, E('em', {}, _('点击集成后读取连接状态。')))
				]);
				self.networkPane = networkPane;

				self.pluginSectionNode = E('div', {}, self.renderPluginManagement(plugin));

				var networkTab = E('div', { 'data-tab': 'network', 'data-tab-title': _('集成') }, [
					networkPane,
					self.pluginSectionNode
				]);
				networkTab.addEventListener('cbi-tab-active', function() {
					self.loadNetworkPane(networkPane);
				});

				var panes = E('div', {}, [
					E('div', { 'data-tab': 'overview', 'data-tab-title': _('概览') }, overviewEl),
					E('div', { 'data-tab': 'core', 'data-tab-title': _('核心管理') }, self.coreSectionNode),
					networkTab,
					E('div', { 'data-tab': 'logs', 'data-tab-title': _('日志') }, self.renderLogs(logs))
				]);
				var tabs = E('div', {}, panes);

				ui.tabs.initTabGroup(panes.childNodes);
				window.setTimeout(self.restoreRunningTask.bind(self), 0);

				return E('div', {}, [
					E('div', { 'class': 'cbi-map-descr' }, [
						_('VoHive 的 OpenWrt 管理插件，在路由器界面中完成核心安装、服务控制与配置管理。'),
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
