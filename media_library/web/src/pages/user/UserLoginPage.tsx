import React, { useState } from 'react';
import { Link } from 'react-router-dom';
import {
  AlertCircle,
  ArrowLeft,
  KeyRound,
  Loader2,
  Lock,
  LogIn,
  ShieldCheck,
  UserCheck,
} from 'lucide-react';
import { ApiError } from '../../api/client';
import { setUserToken, userApi } from '../../api/userClient';
import { useApp } from '../../contexts/AppContext';
import { useUser } from '../../contexts/UserContext';
import type { MemberView } from '../../types';
import { ROLE_LABELS } from '../../utils/userPerms';
import { BrandLogo } from '../../components/BrandLogo';

function formatUserAuthError(err: unknown): string {
  if (err instanceof ApiError) {
    if (err.status === 401 || err.errorCode === 'invalid_credentials') {
      return '用户名、密码或 PIN 码错误';
    }
    if (err.status === 403 || err.errorCode === 'forbidden') {
      return '该账号或成员当前被禁用，请联系管理员';
    }
    if (err.status === 429 || err.errorCode === 'rate_limited') {
      return '尝试过于频繁，请稍后再试';
    }
    return err.message || `请求失败 (${err.status})`;
  }
  if (err instanceof Error && err.message) {
    return err.message;
  }
  return '登录失败，请检查网络连接';
}

export const UserLoginPage: React.FC = () => {
  const { bootstrap, toast } = useApp();
  const { refreshUserAuth } = useUser();

  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [errorMsg, setErrorMsg] = useState('');

  // Multi-member selection flow
  const [loginTicket, setLoginTicket] = useState('');
  const [members, setMembers] = useState<MemberView[]>([]);
  const [selectedMember, setSelectedMember] = useState<MemberView | null>(null);
  const [pin, setPin] = useState('');

  const serverTitle = bootstrap?.server_name || 'TTPlay Media Library';

  const completeLogin = async (accessToken?: string) => {
    if (!accessToken) {
      throw new Error('服务端未返回访问令牌');
    }
    setUserToken(accessToken);
    toast('登录成功', 'success');
    await refreshUserAuth();
  };

  const handleLogin = async (e: React.FormEvent) => {
    e.preventDefault();
    if (busy) return;
    setBusy(true);
    setErrorMsg('');
    try {
      const res = await userApi.login(username.trim(), password);
      if (res.requires_member_select && res.login_ticket) {
        setLoginTicket(res.login_ticket);
        setMembers(res.members || []);
        setSelectedMember(null);
        setPin('');
        return;
      }
      await completeLogin(res.access_token);
    } catch (err) {
      const msg = formatUserAuthError(err);
      setErrorMsg(msg);
      toast(msg, 'error');
    } finally {
      setBusy(false);
    }
  };

  const submitMemberSelection = async (member: MemberView, pinValue?: string) => {
    if (busy || !loginTicket) return;
    setBusy(true);
    setErrorMsg('');
    try {
      const res = await userApi.selectMember(loginTicket, member.id, pinValue);
      await completeLogin(res.access_token);
    } catch (err) {
      const msg = formatUserAuthError(err);
      setErrorMsg(msg);
      toast(msg, 'error');
    } finally {
      setBusy(false);
    }
  };

  const handleMemberCardClick = (member: MemberView) => {
    setErrorMsg('');
    if (member.has_pin) {
      setSelectedMember(member);
      setPin('');
      return;
    }
    void submitMemberSelection(member);
  };

  const handlePinSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (!selectedMember) return;
    void submitMemberSelection(selectedMember, pin);
  };

  const resetToPasswordLogin = () => {
    setLoginTicket('');
    setMembers([]);
    setSelectedMember(null);
    setPin('');
    setErrorMsg('');
  };

  return (
    <div className="auth-screen">
      {loginTicket ? (
        <div className="glass-panel auth-card" style={{ maxWidth: 460 }}>
          <div className="flex-row" style={{ gap: 12 }}>
            <span className="brand-mark" style={{ width: 42, height: 42 }}>
              <UserCheck size={20} />
            </span>
            <div>
              <h2 style={{ margin: 0, fontSize: 20 }}>选择家庭成员</h2>
              <div className="muted-sm">请选择要进入用户面板的成员身份</div>
            </div>
          </div>

          {!selectedMember ? (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
              {members.map((m) => (
                <button
                  key={m.id}
                  type="button"
                  className="setting-row"
                  style={{ cursor: 'pointer', textAlign: 'left', width: '100%' }}
                  disabled={busy}
                  onClick={() => handleMemberCardClick(m)}
                >
                  <div className="flex-row" style={{ gap: 10 }}>
                    <span className="avatar-circle">{(m.nickname || 'M').slice(0, 1)}</span>
                    <div className="setting-row-text">
                      <span className="setting-row-title">{m.nickname}</span>
                      <span className="setting-row-desc">{ROLE_LABELS[m.role] || m.role}</span>
                    </div>
                  </div>
                  <div className="flex-row" style={{ gap: 6 }}>
                    {m.has_pin && (
                      <span className="tag gold">
                        <Lock size={11} /> PIN
                      </span>
                    )}
                    {busy && <Loader2 size={14} className="spin" />}
                  </div>
                </button>
              ))}
            </div>
          ) : (
            <form onSubmit={handlePinSubmit} style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
              <div className="setting-row" style={{ padding: '10px 12px' }}>
                <div className="flex-row" style={{ gap: 10 }}>
                  <span className="avatar-circle">{(selectedMember.nickname || 'M').slice(0, 1)}</span>
                  <div className="setting-row-text">
                    <span className="setting-row-title">{selectedMember.nickname}</span>
                    <span className="setting-row-desc">需要验证成员 PIN 码</span>
                  </div>
                </div>
                <button
                  type="button"
                  className="btn btn-sm"
                  onClick={() => {
                    setSelectedMember(null);
                    setPin('');
                    setErrorMsg('');
                  }}
                >
                  重选
                </button>
              </div>

              <div className="field">
                <label>成员 PIN 码</label>
                <input
                  className="input"
                  type="password"
                  required
                  autoFocus
                  placeholder="请输入成员 PIN"
                  value={pin}
                  onChange={(e) => {
                    setPin(e.target.value);
                    if (errorMsg) setErrorMsg('');
                  }}
                />
              </div>

              <button type="submit" className="btn btn-primary" disabled={busy}>
                {busy ? <Loader2 size={16} className="spin" /> : <KeyRound size={16} />}
                {busy ? '正在验证...' : '确认进入'}
              </button>
            </form>
          )}

          {errorMsg && (
            <div
              role="alert"
              className="flex-row"
              style={{
                gap: 8,
                padding: '10px 12px',
                borderRadius: 10,
                background: 'rgba(239, 68, 68, 0.12)',
                border: '1px solid rgba(239, 68, 68, 0.35)',
                color: 'var(--danger)',
                fontSize: 13,
              }}
            >
              <AlertCircle size={15} style={{ flexShrink: 0 }} />
              <span>{errorMsg}</span>
            </div>
          )}

          <button type="button" className="btn btn-sm" onClick={resetToPasswordLogin} disabled={busy}>
            <ArrowLeft size={14} /> 返回账号登录
          </button>
        </div>
      ) : (
        <form className="glass-panel auth-card" onSubmit={handleLogin}>
          <div className="flex-row" style={{ gap: 12 }}>
            <BrandLogo size={44} alt={serverTitle} />
            <div>
              <h2 style={{ margin: 0, fontSize: 20 }}>{serverTitle}</h2>
              <div className="muted-sm">用户中心登录</div>
            </div>
          </div>

          <div className="setting-row" style={{ padding: '10px 12px' }}>
            <div className="flex-row" style={{ gap: 8, flexWrap: 'nowrap' }}>
              <ShieldCheck size={16} style={{ color: 'var(--accent)', flexShrink: 0 }} />
              <span className="muted-sm" style={{ lineHeight: 1.45 }}>
                使用 TTPlay 客户端账号登录，管理个人媒体源、查看已登录设备及账号安全设置。
              </span>
            </div>
          </div>

          <div className="field">
            <label>用户名 / 邮箱</label>
            <input
              className="input"
              required
              autoFocus
              placeholder="请输入用户名"
              value={username}
              onChange={(e) => {
                setUsername(e.target.value);
                if (errorMsg) setErrorMsg('');
              }}
            />
          </div>

          <div className="field">
            <label>密码</label>
            <input
              className="input"
              type="password"
              required
              placeholder="请输入登录密码"
              value={password}
              onChange={(e) => {
                setPassword(e.target.value);
                if (errorMsg) setErrorMsg('');
              }}
            />
          </div>

          {errorMsg && (
            <div
              role="alert"
              className="flex-row"
              style={{
                gap: 8,
                padding: '10px 12px',
                borderRadius: 10,
                background: 'rgba(239, 68, 68, 0.12)',
                border: '1px solid rgba(239, 68, 68, 0.35)',
                color: 'var(--danger)',
                fontSize: 13,
              }}
            >
              <AlertCircle size={15} style={{ flexShrink: 0 }} />
              <span>{errorMsg}</span>
            </div>
          )}

          <button type="submit" className="btn btn-primary" disabled={busy}>
            {busy ? <Loader2 size={16} className="spin" /> : <LogIn size={16} />}
            {busy ? '正在登录...' : '登录用户面板'}
          </button>

          <div className="flex-row" style={{ justifyContent: 'center', paddingTop: 4 }}>
            <Link to="/admin" className="muted-sm" style={{ textDecoration: 'underline', textUnderlineOffset: 3 }}>
              平台管理员入口 →
            </Link>
          </div>
        </form>
      )}
    </div>
  );
};
