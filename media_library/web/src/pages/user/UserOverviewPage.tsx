import React, { useCallback, useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import {
  Activity,
  ArrowRight,
  FolderCog,
  HardDrive,
  MonitorSmartphone,
  RefreshCw,
  Users,
} from 'lucide-react';
import { formatBytes, formatDateTime } from '../../api/client';
import { userApi } from '../../api/userClient';
import { CardListSkeleton } from '../../components/Skeletons';
import { useApp } from '../../contexts/AppContext';
import { useUser } from '../../contexts/UserContext';
import type { DeviceView, SessionView, SourceView } from '../../types';
import {
  CREDENTIAL_STATUS_LABELS,
  DEVICE_CLASS_LABELS,
  SOURCE_KIND_LABELS,
} from '../../utils/userPerms';

export const UserOverviewPage: React.FC = () => {
  const { toast } = useApp();
  const { household, members } = useUser();

  const [sources, setSources] = useState<SourceView[]>([]);
  const [devices, setDevices] = useState<DeviceView[]>([]);
  const [sessions, setSessions] = useState<SessionView[]>([]);
  const [loading, setLoading] = useState(true);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const [srcRes, devRes, sessRes] = await Promise.all([
        userApi.listSources(),
        userApi.listDevices(),
        userApi.listSessions(),
      ]);
      setSources(srcRes.sources || []);
      setDevices(devRes.devices || []);
      setSessions(sessRes.sessions || []);
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setLoading(false);
    }
  }, [toast]);

  useEffect(() => {
    void load();
  }, [load]);

  const maxSources = household?.quota_max_sources ?? 0;
  const maxFiles = household?.quota_max_files ?? 0;
  const maxSidecar = household?.quota_max_sidecar_bytes ?? 0;

  return (
    <div className="page-stack">
      <div className="page-header">
        <div>
          <h1 className="page-title">欢迎回来{household?.name ? ` · ${household.name}` : ''}</h1>
          <p className="page-subtitle">
            查看当前媒体空间配额、已接入的媒体源状态及所有授权设备与在线会话。
          </p>
        </div>
        <button type="button" className="btn" onClick={() => void load()} disabled={loading}>
          <RefreshCw size={15} className={loading ? 'spin' : ''} />
          刷新数据
        </button>
      </div>

      {loading && sources.length === 0 && devices.length === 0 ? (
        <CardListSkeleton count={4} />
      ) : (
        <>
          <div className="kpi-grid">
            <div className="kpi-card">
              <div className="kpi-head">
                <span className="kpi-label">媒体源数量</span>
                <span className="kpi-icon">
                  <FolderCog size={16} />
                </span>
              </div>
              <div className="kpi-value">
                {sources.length}
                {maxSources > 0 && (
                  <span className="muted-sm" style={{ fontSize: 14, fontWeight: 500 }}>
                    {' '}/ {maxSources}
                  </span>
                )}
              </div>
              <div className="kpi-meta">
                <span>
                  {sources.filter((s) => s.credential_meta?.status === 'valid').length} 个凭据正常
                </span>
              </div>
            </div>

            <div className="kpi-card">
              <div className="kpi-head">
                <span className="kpi-label">已登录设备</span>
                <span className="kpi-icon success">
                  <MonitorSmartphone size={16} />
                </span>
              </div>
              <div className="kpi-value">{devices.length}</div>
              <div className="kpi-meta">
                <span>活跃会话 {sessions.length} 个</span>
              </div>
            </div>

            <div className="kpi-card">
              <div className="kpi-head">
                <span className="kpi-label">家庭成员</span>
                <span className="kpi-icon plum">
                  <Users size={16} />
                </span>
              </div>
              <div className="kpi-value">{household?.member_count ?? members.length}</div>
              <div className="kpi-meta">
                <span>默认语言：{household?.display_lang || 'zh-CN'}</span>
              </div>
            </div>

            <div className="kpi-card">
              <div className="kpi-head">
                <span className="kpi-label">空间配额上限</span>
                <span className="kpi-icon warn">
                  <HardDrive size={16} />
                </span>
              </div>
              <div className="kpi-value" style={{ fontSize: 20 }}>
                {maxFiles > 0 ? `${maxFiles.toLocaleString()} 文件` : '无限制'}
              </div>
              <div className="kpi-meta">
                <span>Sidecar 上限：{maxSidecar > 0 ? formatBytes(maxSidecar) : '默认'}</span>
              </div>
            </div>
          </div>

          <div className="grid-2">
            <div className="glass-panel" style={{ padding: 20 }}>
              <div className="card-title-row">
                <h2 className="card-title">
                  <FolderCog size={16} style={{ color: 'var(--accent)' }} />
                  媒体源状态
                </h2>
                <Link to="/app/sources" className="btn btn-sm">
                  管理全部 <ArrowRight size={13} />
                </Link>
              </div>
              {sources.length === 0 ? (
                <div className="empty-state" style={{ padding: '28px 16px' }}>
                  <p className="muted-sm" style={{ margin: 0 }}>
                    暂无媒体源，请在 TTPlay 客户端中添加媒体源。
                  </p>
                </div>
              ) : (
                <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
                  {sources.slice(0, 5).map((src) => {
                    const cred = CREDENTIAL_STATUS_LABELS[src.credential_meta?.status || ''];
                    return (
                      <div key={src.id} className="setting-row">
                        <div className="setting-row-text">
                          <span className="setting-row-title">{src.name}</span>
                          <span className="setting-row-desc">
                            {SOURCE_KIND_LABELS[src.kind] || src.kind}
                            {src.folders ? ` · ${src.folders.length} 个目录` : ''}
                            {src.scan_state?.last_full_scan_at
                              ? ` · 上次扫描 ${formatDateTime(src.scan_state.last_full_scan_at)}`
                              : ''}
                          </span>
                        </div>
                        {cred && <span className={`tag ${cred.tagClass}`}>{cred.label}</span>}
                      </div>
                    );
                  })}
                </div>
              )}
            </div>

            <div className="glass-panel" style={{ padding: 20 }}>
              <div className="card-title-row">
                <h2 className="card-title">
                  <Activity size={16} style={{ color: 'var(--success)' }} />
                  近期活跃设备
                </h2>
                <Link to="/app/devices" className="btn btn-sm">
                  设备与会话 <ArrowRight size={13} />
                </Link>
              </div>
              {devices.length === 0 ? (
                <div className="empty-state" style={{ padding: '28px 16px' }}>
                  <p className="muted-sm" style={{ margin: 0 }}>暂无已记录的设备。</p>
                </div>
              ) : (
                <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
                  {devices.slice(0, 5).map((dev) => (
                    <div key={dev.id} className="setting-row">
                      <div className="setting-row-text">
                        <div className="flex-row" style={{ gap: 6 }}>
                          <span className="setting-row-title">{dev.name || '未命名设备'}</span>
                          {dev.is_current_device && <span className="tag accent">当前设备</span>}
                        </div>
                        <span className="setting-row-desc">
                          {DEVICE_CLASS_LABELS[dev.device_class] || dev.device_class} · {dev.platform || '-'}
                          {dev.app_version ? ` · v${dev.app_version}` : ''}
                        </span>
                      </div>
                      <span className="muted-sm" style={{ fontSize: 12, whiteSpace: 'nowrap' }}>
                        {formatDateTime(dev.last_seen_at || dev.created_at)}
                      </span>
                    </div>
                  ))}
                </div>
              )}
            </div>
          </div>
        </>
      )}
    </div>
  );
};
