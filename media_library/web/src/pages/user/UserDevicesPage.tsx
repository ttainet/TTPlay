import React, { useCallback, useEffect, useState } from 'react';
import {
  Laptop,
  Loader2,
  LogOut,
  MonitorSmartphone,
  RefreshCw,
  ShieldAlert,
  Smartphone,
  Tablet,
  Trash2,
  Tv,
  Globe,
  X,
} from 'lucide-react';
import { formatDateTime } from '../../api/client';
import { userApi } from '../../api/userClient';
import { ModalBackdrop } from '../../components/ModalBackdrop';
import { TableSkeleton } from '../../components/Skeletons';
import { useApp } from '../../contexts/AppContext';
import { useUser } from '../../contexts/UserContext';
import type { DeviceView, SessionView } from '../../types';
import { DEVICE_CLASS_LABELS } from '../../utils/userPerms';

function DeviceIcon({ deviceClass }: { deviceClass?: string }) {
  switch (deviceClass) {
    case 'phone':
      return <Smartphone size={15} />;
    case 'tablet':
      return <Tablet size={15} />;
    case 'tv':
      return <Tv size={15} />;
    case 'desktop':
      return <Laptop size={15} />;
    default:
      return <Globe size={15} />;
  }
}

export const UserDevicesPage: React.FC = () => {
  const { toast } = useApp();
  const { userLogout } = useUser();

  const [tab, setTab] = useState<'devices' | 'sessions'>('devices');
  const [devices, setDevices] = useState<DeviceView[]>([]);
  const [sessions, setSessions] = useState<SessionView[]>([]);
  const [loading, setLoading] = useState(true);

  const [revokeDeviceTarget, setRevokeDeviceTarget] = useState<DeviceView | null>(null);
  const [revokeSessionTarget, setRevokeSessionTarget] = useState<SessionView | null>(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const [devRes, sessRes] = await Promise.all([
        userApi.listDevices(),
        userApi.listSessions(),
      ]);
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

  const handleRevokeDevice = async () => {
    if (!revokeDeviceTarget || busy) return;
    setBusy(true);
    const isCurrent = revokeDeviceTarget.is_current_device;
    const devName = revokeDeviceTarget.name || revokeDeviceTarget.id;
    try {
      await userApi.revokeDevice(revokeDeviceTarget.id);
      setRevokeDeviceTarget(null);
      if (isCurrent) {
        toast('已移除当前设备，正在退出登录', 'info');
        await userLogout();
        return;
      }
      toast(`已移除设备「${devName}」及其关联会话`, 'success');
      await load();
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setBusy(false);
    }
  };

  const handleRevokeSession = async () => {
    if (!revokeSessionTarget || busy) return;
    setBusy(true);
    const isCurrent = revokeSessionTarget.is_current_session;
    try {
      await userApi.revokeSession(revokeSessionTarget.token_id);
      setRevokeSessionTarget(null);
      if (isCurrent) {
        toast('已注销当前会话，请重新登录', 'info');
        await userLogout();
        return;
      }
      toast('已强制下线该会话', 'success');
      await load();
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="page-stack">
      <div className="page-header">
        <div>
          <h1 className="page-title">登录设备与在线会话</h1>
          <p className="page-subtitle">
            查看当前家庭账号关联的所有终端设备与活跃会话；发现异常终端可立即踢下线或吊销设备授权。
          </p>
        </div>
        <button type="button" className="btn" onClick={() => void load()} disabled={loading}>
          <RefreshCw size={15} className={loading ? 'spin' : ''} />
          刷新列表
        </button>
      </div>

      <div className="flex-row" style={{ justifyContent: 'space-between', flexWrap: 'wrap' }}>
        <div className="tab-bar">
          <button
            type="button"
            className={`tab-btn ${tab === 'devices' ? 'active' : ''}`}
            onClick={() => setTab('devices')}
          >
            <MonitorSmartphone size={14} /> 已登录设备 ({devices.length})
          </button>
          <button
            type="button"
            className={`tab-btn ${tab === 'sessions' ? 'active' : ''}`}
            onClick={() => setTab('sessions')}
          >
            <ShieldAlert size={14} /> 活跃会话 ({sessions.length})
          </button>
        </div>
      </div>

      <div className="glass-panel" style={{ padding: 18 }}>
        {loading && devices.length === 0 && sessions.length === 0 ? (
          <TableSkeleton rows={4} />
        ) : tab === 'devices' ? (
          devices.length === 0 ? (
            <div className="empty-state">
              <MonitorSmartphone size={36} style={{ opacity: 0.45 }} />
              <p className="muted" style={{ margin: '10px 0 0' }}>暂无已记录的设备。</p>
            </div>
          ) : (
            <div className="table-wrap">
              <table className="data-table">
                <thead>
                  <tr>
                    <th>设备名称</th>
                    <th>终端类型</th>
                    <th>系统平台</th>
                    <th>客户端版本</th>
                    <th>最近活跃</th>
                    <th>首次登记</th>
                    <th style={{ textAlign: 'right' }}>操作</th>
                  </tr>
                </thead>
                <tbody>
                  {devices.map((dev) => (
                    <tr key={dev.id}>
                      <td>
                        <div className="flex-row" style={{ gap: 8 }}>
                          <span className="muted"><DeviceIcon deviceClass={dev.device_class} /></span>
                          <div>
                            <div className="flex-row" style={{ gap: 6 }}>
                              <span style={{ fontWeight: 600 }}>{dev.name || '未命名设备'}</span>
                              {dev.is_current_device && <span className="tag accent">当前设备</span>}
                            </div>
                            <div className="muted-sm" style={{ fontSize: 11, fontFamily: 'var(--font-mono)' }}>
                              {dev.id}
                            </div>
                          </div>
                        </div>
                      </td>
                      <td>{DEVICE_CLASS_LABELS[dev.device_class] || dev.device_class}</td>
                      <td>{dev.platform || '-'}</td>
                      <td>{dev.app_version ? `v${dev.app_version}` : '-'}</td>
                      <td className="muted-sm">{formatDateTime(dev.last_seen_at || dev.created_at)}</td>
                      <td className="muted-sm">{formatDateTime(dev.created_at)}</td>
                      <td>
                        <div className="flex-row" style={{ justifyContent: 'flex-end' }}>
                          <button
                            type="button"
                            className="btn btn-danger btn-sm"
                            onClick={() => setRevokeDeviceTarget(dev)}
                          >
                            <Trash2 size={13} /> {dev.is_current_device ? '移除并登出' : '移除设备'}
                          </button>
                        </div>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )
        ) : sessions.length === 0 ? (
          <div className="empty-state">
            <ShieldAlert size={36} style={{ opacity: 0.45 }} />
            <p className="muted" style={{ margin: '10px 0 0' }}>暂无活跃会话。</p>
          </div>
        ) : (
          <div className="table-wrap">
            <table className="data-table">
              <thead>
                <tr>
                  <th>成员 / 设备</th>
                  <th>登录模式</th>
                  <th>来源 IP</th>
                  <th>最近使用</th>
                  <th>过期时间</th>
                  <th style={{ textAlign: 'right' }}>操作</th>
                </tr>
              </thead>
              <tbody>
                {sessions.map((sess) => (
                  <tr key={sess.token_id}>
                    <td>
                      <div className="flex-row" style={{ gap: 8 }}>
                        <span className="muted"><DeviceIcon deviceClass={sess.device_class} /></span>
                        <div>
                          <div className="flex-row" style={{ gap: 6 }}>
                            <span style={{ fontWeight: 600 }}>
                              {sess.device_name || sess.device_id}
                            </span>
                            {sess.is_current_session && <span className="tag accent">当前会话</span>}
                          </div>
                          <div className="muted-sm" style={{ fontSize: 12 }}>
                            成员：{sess.member_nickname || sess.member_id}
                          </div>
                        </div>
                      </div>
                    </td>
                    <td>
                      <span className="tag">
                        {sess.login_mode === 'household' ? '主账号会话' : '独立成员会话'}
                      </span>
                    </td>
                    <td style={{ fontFamily: 'var(--font-mono)', fontSize: 12.5 }}>{sess.ip || '-'}</td>
                    <td className="muted-sm">{formatDateTime(sess.last_used_at)}</td>
                    <td className="muted-sm">{formatDateTime(sess.expires_at)}</td>
                    <td>
                      <div className="flex-row" style={{ justifyContent: 'flex-end' }}>
                        <button
                          type="button"
                          className="btn btn-danger btn-sm"
                          onClick={() => setRevokeSessionTarget(sess)}
                        >
                          <LogOut size={13} /> {sess.is_current_session ? '退出会话' : '强制下线'}
                        </button>
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>

      {/* Revoke Device Modal */}
      {revokeDeviceTarget && (
        <ModalBackdrop onClose={() => !busy && setRevokeDeviceTarget(null)}>
          <div className="modal-panel" style={{ maxWidth: 440 }}>
            <div className="modal-header">
              <h3 style={{ color: 'var(--danger)' }}>确认移除设备</h3>
              <button type="button" className="btn btn-icon btn-sm" onClick={() => setRevokeDeviceTarget(null)}>
                <X size={15} />
              </button>
            </div>
            <div className="modal-body">
              <p style={{ margin: 0, fontSize: 14, lineHeight: 1.6 }}>
                确定要移除设备 <strong>{revokeDeviceTarget.name || revokeDeviceTarget.id}</strong> 吗？
              </p>
              <p className="muted-sm" style={{ margin: '10px 0 0', lineHeight: 1.5 }}>
                移除后，该设备上所有已登录的会话将立即失效。
                {revokeDeviceTarget.is_current_device ? '（注意：这是你当前正在使用的浏览器，移除后将立即退出登录。）' : ''}
              </p>
            </div>
            <div className="modal-footer">
              <button type="button" className="btn" onClick={() => setRevokeDeviceTarget(null)} disabled={busy}>
                取消
              </button>
              <button type="button" className="btn btn-danger" onClick={() => void handleRevokeDevice()} disabled={busy}>
                {busy ? <Loader2 size={14} className="spin" /> : <Trash2 size={14} />}
                确认移除
              </button>
            </div>
          </div>
        </ModalBackdrop>
      )}

      {/* Revoke Session Modal */}
      {revokeSessionTarget && (
        <ModalBackdrop onClose={() => !busy && setRevokeSessionTarget(null)}>
          <div className="modal-panel" style={{ maxWidth: 440 }}>
            <div className="modal-header">
              <h3 style={{ color: 'var(--danger)' }}>确认注销会话</h3>
              <button type="button" className="btn btn-icon btn-sm" onClick={() => setRevokeSessionTarget(null)}>
                <X size={15} />
              </button>
            </div>
            <div className="modal-body">
              <p style={{ margin: 0, fontSize: 14, lineHeight: 1.6 }}>
                确定要注销设备 <strong>{revokeSessionTarget.device_name || revokeSessionTarget.device_id}</strong>（IP: {revokeSessionTarget.ip || '-'}）的登录会话吗？
              </p>
              {revokeSessionTarget.is_current_session && (
                <p className="muted-sm" style={{ margin: '10px 0 0', color: 'var(--warning)' }}>
                  这是当前会话，注销后页面将立即跳转回登录界面。
                </p>
              )}
            </div>
            <div className="modal-footer">
              <button type="button" className="btn" onClick={() => setRevokeSessionTarget(null)} disabled={busy}>
                取消
              </button>
              <button type="button" className="btn btn-danger" onClick={() => void handleRevokeSession()} disabled={busy}>
                {busy ? <Loader2 size={14} className="spin" /> : <LogOut size={14} />}
                确认注销
              </button>
            </div>
          </div>
        </ModalBackdrop>
      )}
    </div>
  );
};
