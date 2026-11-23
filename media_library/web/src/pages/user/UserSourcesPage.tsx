import React, { useCallback, useEffect, useState } from 'react';
import {
  Edit3,
  FolderOpen,
  FolderPlus,
  History,
  Loader2,
  Plus,
  RefreshCw,
  Trash2,
  X,
} from 'lucide-react';
import { formatDateTime } from '../../api/client';
import { userApi } from '../../api/userClient';
import { CustomSelect } from '../../components/CustomSelect';
import { ModalBackdrop } from '../../components/ModalBackdrop';
import { TableSkeleton } from '../../components/Skeletons';
import { useApp } from '../../contexts/AppContext';
import { useUser } from '../../contexts/UserContext';
import type { FolderView, ScanSessionView, SourceView } from '../../types';
import {
  CREDENTIAL_STATUS_LABELS,
  LIBRARY_HINT_LABELS,
  LIBRARY_HINT_OPTIONS,
  SCAN_STATUS_LABELS,
  SOURCE_KINDS_WITH_FOLDERS,
  SOURCE_KIND_LABELS,
  UserPerm,
  hasUserPerm,
} from '../../utils/userPerms';

function kindTagClass(kind: string): string {
  if (kind === 'emby') return 'emby';
  if (kind === 'jellyfin') return 'jellyfin';
  if (kind === 'quark') return 'accent';
  return '';
}

export const UserSourcesPage: React.FC = () => {
  const { toast } = useApp();
  const { principal } = useUser();
  const canManage = hasUserPerm(principal, UserPerm.ManageSources);

  const [sources, setSources] = useState<SourceView[]>([]);
  const [loading, setLoading] = useState(true);

  // Rename source modal
  const [renameTarget, setRenameTarget] = useState<SourceView | null>(null);
  const [renameValue, setRenameValue] = useState('');
  const [renameBusy, setRenameBusy] = useState(false);

  // Delete source modal
  const [deleteTarget, setDeleteTarget] = useState<SourceView | null>(null);
  const [deleteBusy, setDeleteBusy] = useState(false);

  // Detail modal (folders & scan history)
  const [detailSource, setDetailSource] = useState<SourceView | null>(null);
  const [detailTab, setDetailTab] = useState<'folders' | 'scans'>('folders');
  const [folders, setFolders] = useState<FolderView[]>([]);
  const [scanSessions, setScanSessions] = useState<ScanSessionView[]>([]);
  const [detailLoading, setDetailLoading] = useState(false);

  // Folder editor modal
  const [folderEditMode, setFolderEditMode] = useState<'add' | 'edit' | null>(null);
  const [editingFolder, setEditingFolder] = useState<FolderView | null>(null);
  const [folderPath, setFolderPath] = useState('');
  const [folderHint, setFolderHint] = useState('auto');
  const [folderExcludes, setFolderExcludes] = useState('');
  const [folderBusy, setFolderBusy] = useState(false);
  const [deleteFolderTarget, setDeleteFolderTarget] = useState<FolderView | null>(null);

  const loadSources = useCallback(async () => {
    setLoading(true);
    try {
      const res = await userApi.listSources();
      setSources(res.sources || []);
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setLoading(false);
    }
  }, [toast]);

  useEffect(() => {
    void loadSources();
  }, [loadSources]);

  const openDetailModal = async (src: SourceView, initialTab?: 'folders' | 'scans') => {
    if (!SOURCE_KINDS_WITH_FOLDERS.has(src.kind)) {
      return;
    }
    const targetTab = initialTab || 'folders';
    setDetailSource(src);
    setDetailTab(targetTab);
    setDetailLoading(true);
    try {
      const [foldersRes, scansRes] = await Promise.all([
        userApi.listFolders(src.id),
        userApi.listSourceScanSessions(src.id),
      ]);
      setFolders(foldersRes.folders || []);
      setScanSessions(scansRes.sessions || []);
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setDetailLoading(false);
    }
  };

  const refreshDetailFolders = async (sourceId: string) => {
    const res = await userApi.listFolders(sourceId);
    setFolders(res.folders || []);
    await loadSources();
  };

  const handleRenameSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!renameTarget || renameBusy) return;
    const trimmed = renameValue.trim();
    if (!trimmed) return;
    setRenameBusy(true);
    try {
      await userApi.updateSource(renameTarget.id, trimmed);
      toast(`已将媒体源重命名为「${trimmed}」`, 'success');
      setRenameTarget(null);
      await loadSources();
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setRenameBusy(false);
    }
  };

  const handleDeleteSource = async () => {
    if (!deleteTarget || deleteBusy) return;
    setDeleteBusy(true);
    try {
      await userApi.deleteSource(deleteTarget.id);
      toast(`已删除媒体源「${deleteTarget.name}」`, 'info');
      if (detailSource?.id === deleteTarget.id) {
        setDetailSource(null);
      }
      setDeleteTarget(null);
      await loadSources();
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setDeleteBusy(false);
    }
  };

  const openAddFolder = () => {
    setFolderEditMode('add');
    setEditingFolder(null);
    setFolderPath('');
    setFolderHint('auto');
    setFolderExcludes('');
  };

  const openEditFolder = (f: FolderView) => {
    setFolderEditMode('edit');
    setEditingFolder(f);
    setFolderPath(f.path);
    setFolderHint(f.library_hint || 'auto');
    setFolderExcludes((f.exclude_paths || []).join('\n'));
  };

  const handleSaveFolder = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!detailSource || folderBusy) return;
    const excludes = folderExcludes
      .split(/\r?\n|,/)
      .map((s) => s.trim())
      .filter(Boolean);
    setFolderBusy(true);
    try {
      if (folderEditMode === 'add') {
        await userApi.addFolder(detailSource.id, {
          path: folderPath.trim(),
          library_hint: folderHint,
          exclude_paths: excludes,
        });
        toast('已添加扫描目录', 'success');
      } else if (folderEditMode === 'edit' && editingFolder) {
        await userApi.updateFolder(detailSource.id, editingFolder.id, {
          path: folderPath.trim(),
          library_hint: folderHint,
          exclude_paths: excludes,
        });
        toast('已更新扫描目录', 'success');
      }
      setFolderEditMode(null);
      setEditingFolder(null);
      await refreshDetailFolders(detailSource.id);
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setFolderBusy(false);
    }
  };

  const handleDeleteFolder = async () => {
    if (!detailSource || !deleteFolderTarget || folderBusy) return;
    setFolderBusy(true);
    try {
      await userApi.deleteFolder(detailSource.id, deleteFolderTarget.id);
      toast('已移除扫描目录', 'info');
      setDeleteFolderTarget(null);
      await refreshDetailFolders(detailSource.id);
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setFolderBusy(false);
    }
  };

  return (
    <div className="page-stack">
      <div className="page-header">
        <div>
          <h1 className="page-title">媒体源管理</h1>
          <p className="page-subtitle">
            查看已在客户端接入的媒体源、扫描目录与同步状态；可执行重命名、目录调整或删除媒体源。
          </p>
        </div>
        <button type="button" className="btn" onClick={() => void loadSources()} disabled={loading}>
          <RefreshCw size={15} className={loading ? 'spin' : ''} />
          刷新列表
        </button>
      </div>

      {!canManage && (
        <div className="setting-row" style={{ borderColor: 'rgba(245, 185, 66, 0.35)' }}>
          <div className="setting-row-text">
            <span className="setting-row-title">当前成员仅拥有只读权限</span>
            <span className="setting-row-desc">当前身份未授予媒体源管理权限（PermManageSources），仅可查看详情。</span>
          </div>
        </div>
      )}

      <div className="glass-panel" style={{ padding: 18 }}>
        {loading && sources.length === 0 ? (
          <TableSkeleton rows={4} />
        ) : sources.length === 0 ? (
          <div className="empty-state">
            <FolderOpen size={36} style={{ opacity: 0.45 }} />
            <p className="muted" style={{ margin: '10px 0 0' }}>
              暂无已添加的媒体源，请在 Plezy 客户端中添加网盘、WebDAV、SMB 或 Emby/Jellyfin 源。
            </p>
          </div>
        ) : (
          <div className="table-wrap">
            <table className="data-table">
              <thead>
                <tr>
                  <th>名称</th>
                  <th>类型</th>
                  <th>凭据状态</th>
                  <th>目录数</th>
                  <th>最近扫描</th>
                  <th>更新时间</th>
                  <th style={{ textAlign: 'right' }}>操作</th>
                </tr>
              </thead>
              <tbody>
                {sources.map((src) => {
                  const cred = CREDENTIAL_STATUS_LABELS[src.credential_meta?.status || ''];
                  const supportsFolders = SOURCE_KINDS_WITH_FOLDERS.has(src.kind);
                  return (
                    <tr key={src.id}>
                      <td>
                        <div style={{ fontWeight: 600 }}>{src.name}</div>
                        <div className="muted-sm" style={{ fontSize: 11, fontFamily: 'var(--font-mono)' }}>
                          {src.identity_key || src.id}
                        </div>
                      </td>
                      <td>
                        <span className={`tag ${kindTagClass(src.kind)}`}>
                          {SOURCE_KIND_LABELS[src.kind] || src.kind}
                        </span>
                      </td>
                      <td>
                        {cred ? (
                          <span className={`tag ${cred.tagClass}`}>{cred.label}</span>
                        ) : (
                          <span className="muted-sm">无凭据</span>
                        )}
                      </td>
                      <td>{supportsFolders ? `${src.folders?.length ?? 0} 个` : '-'}</td>
                      <td>
                        {!supportsFolders ? (
                          <span className="muted-sm">直连源（无需扫描）</span>
                        ) : src.scan_state ? (
                          <div>
                            <div style={{ fontSize: 12.5 }}>{src.scan_state.last_scan_result || '-'}</div>
                            <div className="muted-sm" style={{ fontSize: 11 }}>
                              {formatDateTime(src.scan_state.last_full_scan_at || src.scan_state.updated_at)}
                            </div>
                          </div>
                        ) : (
                          <span className="muted-sm">未扫描</span>
                        )}
                      </td>
                      <td className="muted-sm">{formatDateTime(src.updated_at)}</td>
                      <td>
                        <div className="flex-row" style={{ justifyContent: 'flex-end', gap: 6 }}>
                          {supportsFolders && (
                            <button
                              type="button"
                              className="btn btn-sm"
                              onClick={() => void openDetailModal(src)}
                            >
                              <FolderOpen size={13} /> 目录与记录
                            </button>
                          )}
                          {canManage && (
                            <>
                              <button
                                type="button"
                                className="btn btn-sm"
                                title="重命名媒体源"
                                onClick={() => {
                                  setRenameTarget(src);
                                  setRenameValue(src.name);
                                }}
                              >
                                <Edit3 size={13} /> 重命名
                              </button>
                              <button
                                type="button"
                                className="btn btn-danger btn-sm"
                                title="删除媒体源"
                                onClick={() => setDeleteTarget(src)}
                              >
                                <Trash2 size={13} /> 删除
                              </button>
                            </>
                          )}
                        </div>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </div>

      {/* Rename Source Modal */}
      {renameTarget && (
        <ModalBackdrop onClose={() => !renameBusy && setRenameTarget(null)}>
          <form className="modal-panel" style={{ maxWidth: 440 }} onSubmit={handleRenameSubmit}>
            <div className="modal-header">
              <h3>重命名媒体源</h3>
              <button type="button" className="btn btn-icon btn-sm" onClick={() => setRenameTarget(null)}>
                <X size={15} />
              </button>
            </div>
            <div className="modal-body">
              <div className="field">
                <label>媒体源名称</label>
                <input
                  className="input"
                  required
                  autoFocus
                  maxLength={64}
                  value={renameValue}
                  onChange={(e) => setRenameValue(e.target.value)}
                />
              </div>
            </div>
            <div className="modal-footer">
              <button type="button" className="btn" onClick={() => setRenameTarget(null)} disabled={renameBusy}>
                取消
              </button>
              <button type="submit" className="btn btn-primary" disabled={renameBusy}>
                {renameBusy && <Loader2 size={14} className="spin" />}
                保存名称
              </button>
            </div>
          </form>
        </ModalBackdrop>
      )}

      {/* Delete Source Modal */}
      {deleteTarget && (
        <ModalBackdrop onClose={() => !deleteBusy && setDeleteTarget(null)}>
          <div className="modal-panel" style={{ maxWidth: 460 }}>
            <div className="modal-header">
              <h3 style={{ color: 'var(--danger)' }}>确认删除媒体源</h3>
              <button type="button" className="btn btn-icon btn-sm" onClick={() => setDeleteTarget(null)}>
                <X size={15} />
              </button>
            </div>
            <div className="modal-body">
              <p style={{ margin: 0, lineHeight: 1.6, fontSize: 14 }}>
                确定要删除媒体源 <strong>{deleteTarget.name}</strong>（{SOURCE_KIND_LABELS[deleteTarget.kind] || deleteTarget.kind}）吗？
              </p>
              <p className="muted-sm" style={{ margin: '10px 0 0', lineHeight: 1.5 }}>
                删除后该媒体源将不再出现在各端客户端中，其下的同步条目也会标记失效（服务端保留 30 天软删除缓冲期后自动清理）。
              </p>
            </div>
            <div className="modal-footer">
              <button type="button" className="btn" onClick={() => setDeleteTarget(null)} disabled={deleteBusy}>
                取消
              </button>
              <button type="button" className="btn btn-danger" onClick={() => void handleDeleteSource()} disabled={deleteBusy}>
                {deleteBusy ? <Loader2 size={14} className="spin" /> : <Trash2 size={14} />}
                确认删除
              </button>
            </div>
          </div>
        </ModalBackdrop>
      )}

      {/* Source Detail Modal (Folders + Scan Sessions) */}
      {detailSource && (
        <ModalBackdrop onClose={() => setDetailSource(null)}>
          <div className="modal-panel" style={{ maxWidth: 780 }}>
            <div className="modal-header">
              <div>
                <h3 style={{ margin: 0 }}>{detailSource.name}</h3>
                <div className="muted-sm" style={{ fontSize: 12, marginTop: 2 }}>
                  {SOURCE_KIND_LABELS[detailSource.kind] || detailSource.kind} · {detailSource.id}
                </div>
              </div>
              <button type="button" className="btn btn-icon btn-sm" onClick={() => setDetailSource(null)}>
                <X size={15} />
              </button>
            </div>
            <div className="modal-body" style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
              <div className="flex-row" style={{ justifyContent: 'space-between', flexWrap: 'wrap' }}>
                <div className="tab-bar">
                  {SOURCE_KINDS_WITH_FOLDERS.has(detailSource.kind) && (
                    <button
                      type="button"
                      className={`tab-btn ${detailTab === 'folders' ? 'active' : ''}`}
                      onClick={() => setDetailTab('folders')}
                    >
                      <FolderOpen size={14} /> 扫描目录 ({folders.length})
                    </button>
                  )}
                  <button
                    type="button"
                    className={`tab-btn ${detailTab === 'scans' ? 'active' : ''}`}
                    onClick={() => setDetailTab('scans')}
                  >
                    <History size={14} /> 扫描历史 ({scanSessions.length})
                  </button>
                </div>

                {detailTab === 'folders' && canManage && SOURCE_KINDS_WITH_FOLDERS.has(detailSource.kind) && (
                  <button type="button" className="btn btn-primary btn-sm" onClick={openAddFolder}>
                    <FolderPlus size={14} /> 添加目录
                  </button>
                )}
              </div>

              {detailLoading ? (
                <TableSkeleton rows={3} />
              ) : detailTab === 'folders' ? (
                folders.length === 0 ? (
                  <div className="empty-state" style={{ padding: '28px 16px' }}>
                    <p className="muted-sm" style={{ margin: 0 }}>当前媒体源尚未配置扫描目录。</p>
                  </div>
                ) : (
                  <div className="table-wrap">
                    <table className="data-table">
                      <thead>
                        <tr>
                          <th>目录路径</th>
                          <th>媒体库类型</th>
                          <th>排除规则</th>
                          <th>更新时间</th>
                          {canManage && <th style={{ textAlign: 'right' }}>操作</th>}
                        </tr>
                      </thead>
                      <tbody>
                        {folders.map((f) => (
                          <tr key={f.id}>
                            <td style={{ fontFamily: 'var(--font-mono)', fontSize: 12.5 }}>{f.path}</td>
                            <td>
                              <span className="tag">{LIBRARY_HINT_LABELS[f.library_hint] || f.library_hint}</span>
                            </td>
                            <td className="muted-sm" style={{ fontSize: 12 }}>
                              {f.exclude_paths && f.exclude_paths.length > 0 ? f.exclude_paths.join(', ') : '无'}
                            </td>
                            <td className="muted-sm">{formatDateTime(f.updated_at)}</td>
                            {canManage && (
                              <td>
                                <div className="flex-row" style={{ justifyContent: 'flex-end', gap: 6 }}>
                                  <button type="button" className="btn btn-sm" onClick={() => openEditFolder(f)}>
                                    <Edit3 size={12} /> 编辑
                                  </button>
                                  <button
                                    type="button"
                                    className="btn btn-danger btn-sm"
                                    onClick={() => setDeleteFolderTarget(f)}
                                  >
                                    <Trash2 size={12} />
                                  </button>
                                </div>
                              </td>
                            )}
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                )
              ) : scanSessions.length === 0 ? (
                <div className="empty-state" style={{ padding: '28px 16px' }}>
                  <p className="muted-sm" style={{ margin: 0 }}>暂无扫描会话记录。</p>
                </div>
              ) : (
                <div className="table-wrap">
                  <table className="data-table">
                    <thead>
                      <tr>
                        <th>扫描类型</th>
                        <th>状态</th>
                        <th>上报 / 新增 / 变更 / 缺失</th>
                        <th>进度</th>
                        <th>开始时间</th>
                      </tr>
                    </thead>
                    <tbody>
                      {scanSessions.map((sess) => {
                        const st = SCAN_STATUS_LABELS[sess.status];
                        return (
                          <tr key={sess.id}>
                            <td>{sess.type}</td>
                            <td>
                              {st ? <span className={`tag ${st.tagClass}`}>{st.label}</span> : sess.status}
                            </td>
                            <td style={{ fontVariantNumeric: 'tabular-nums', fontSize: 12.5 }}>
                              {sess.files_reported} / +{sess.files_added} / ~{sess.files_changed} / -{sess.files_missing}
                            </td>
                            <td>{sess.progress_pct}%</td>
                            <td className="muted-sm">{formatDateTime(sess.started_at)}</td>
                          </tr>
                        );
                      })}
                    </tbody>
                  </table>
                </div>
              )}
            </div>
            <div className="modal-footer">
              <button type="button" className="btn" onClick={() => setDetailSource(null)}>
                关闭
              </button>
            </div>
          </div>
        </ModalBackdrop>
      )}

      {/* Add / Edit Folder Sub-Modal */}
      {folderEditMode && (
        <ModalBackdrop subModal onClose={() => !folderBusy && setFolderEditMode(null)}>
          <form className="modal-panel" style={{ maxWidth: 480 }} onSubmit={handleSaveFolder}>
            <div className="modal-header">
              <h3>{folderEditMode === 'add' ? '添加扫描目录' : '编辑扫描目录'}</h3>
              <button type="button" className="btn btn-icon btn-sm" onClick={() => setFolderEditMode(null)}>
                <X size={15} />
              </button>
            </div>
            <div className="modal-body">
              <div className="field">
                <label>目录路径</label>
                <input
                  className="input"
                  required
                  autoFocus
                  placeholder="例如：/电影 或 /Anime"
                  value={folderPath}
                  onChange={(e) => setFolderPath(e.target.value)}
                />
              </div>
              <div className="field">
                <label>内容类型提示</label>
                <CustomSelect value={folderHint} onChange={setFolderHint} options={LIBRARY_HINT_OPTIONS} />
              </div>
              <div className="field">
                <label>排除子路径（可选，每行或逗号分隔）</label>
                <textarea
                  className="input"
                  rows={3}
                  placeholder="/电影/预告片"
                  value={folderExcludes}
                  onChange={(e) => setFolderExcludes(e.target.value)}
                />
              </div>
            </div>
            <div className="modal-footer">
              <button type="button" className="btn" onClick={() => setFolderEditMode(null)} disabled={folderBusy}>
                取消
              </button>
              <button type="submit" className="btn btn-primary" disabled={folderBusy}>
                {folderBusy ? <Loader2 size={14} className="spin" /> : <Plus size={14} />}
                保存目录
              </button>
            </div>
          </form>
        </ModalBackdrop>
      )}

      {/* Delete Folder Sub-Modal */}
      {deleteFolderTarget && (
        <ModalBackdrop subModal onClose={() => !folderBusy && setDeleteFolderTarget(null)}>
          <div className="modal-panel" style={{ maxWidth: 420 }}>
            <div className="modal-header">
              <h3 style={{ color: 'var(--danger)' }}>移除扫描目录</h3>
              <button type="button" className="btn btn-icon btn-sm" onClick={() => setDeleteFolderTarget(null)}>
                <X size={15} />
              </button>
            </div>
            <div className="modal-body">
              <p style={{ margin: 0, fontSize: 14, lineHeight: 1.6 }}>
                确认移除扫描目录 <code style={{ fontFamily: 'var(--font-mono)' }}>{deleteFolderTarget.path}</code> 吗？
              </p>
            </div>
            <div className="modal-footer">
              <button type="button" className="btn" onClick={() => setDeleteFolderTarget(null)} disabled={folderBusy}>
                取消
              </button>
              <button type="button" className="btn btn-danger" onClick={() => void handleDeleteFolder()} disabled={folderBusy}>
                {folderBusy ? <Loader2 size={14} className="spin" /> : <Trash2 size={14} />}
                确认移除
              </button>
            </div>
          </div>
        </ModalBackdrop>
      )}
    </div>
  );
};
