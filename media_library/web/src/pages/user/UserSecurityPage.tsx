import React, { useEffect, useState } from 'react';
import { Home, Info, KeyRound, Loader2, LogOut, Save, Shield } from 'lucide-react';
import { formatDateTime } from '../../api/client';
import { userApi } from '../../api/userClient';
import { CustomSelect } from '../../components/CustomSelect';
import { useApp } from '../../contexts/AppContext';
import { useUser } from '../../contexts/UserContext';
import { ROLE_LABELS, UserPerm, hasUserPerm } from '../../utils/userPerms';

const LANG_OPTIONS = [
  { value: 'zh-CN', label: '简体中文 (zh-CN)' },
  { value: 'zh-TW', label: '繁體中文 (zh-TW)' },
  { value: 'en-US', label: 'English (en-US)' },
  { value: 'ja-JP', label: '日本語 (ja-JP)' },
];

export const UserSecurityPage: React.FC = () => {
  const { toast } = useApp();
  const { principal, household, setHouseholdLocal, userLogout } = useUser();

  const canManageSettings = hasUserPerm(principal, UserPerm.ManageSettings);
  const canChangeAccountPw = principal?.role === 'owner' && principal?.login_mode === 'household';

  const [hhName, setHhName] = useState(household?.name || '');
  const [hhLang, setHhLang] = useState(household?.display_lang || 'zh-CN');
  const [hhBusy, setHhBusy] = useState(false);

  const [oldPassword, setOldPassword] = useState('');
  const [newPassword, setNewPassword] = useState('');
  const [confirmPassword, setConfirmPassword] = useState('');
  const [pwBusy, setPwBusy] = useState(false);

  useEffect(() => {
    if (household) {
      setHhName(household.name);
      setHhLang(household.display_lang || 'zh-CN');
    }
  }, [household]);

  const handleSaveHousehold = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!canManageSettings || hhBusy) return;
    setHhBusy(true);
    try {
      const res = await userApi.updateHousehold({
        name: hhName.trim(),
        display_lang: hhLang,
      });
      if (res.household) {
        setHouseholdLocal(res.household);
      }
      toast('家庭信息已更新', 'success');
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setHhBusy(false);
    }
  };

  const handleChangePassword = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!canChangeAccountPw || pwBusy) return;
    if (newPassword !== confirmPassword) {
      toast('两次输入的新密码不一致', 'error');
      return;
    }
    setPwBusy(true);
    try {
      await userApi.changePassword(oldPassword, newPassword);
      setOldPassword('');
      setNewPassword('');
      setConfirmPassword('');
      toast('登录密码已更新', 'success');
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setPwBusy(false);
    }
  };

  return (
    <div className="page-stack">
      <div className="page-header">
        <div>
          <h1 className="page-title">账号与安全</h1>
          <p className="page-subtitle">查看当前成员身份、管理家庭空间资料及更新主账号密码。</p>
        </div>
        <button type="button" className="btn btn-danger" onClick={() => void userLogout()}>
          <LogOut size={15} /> 退出登录
        </button>
      </div>

      <div className="grid-2">
        {/* Identity Summary */}
        <div className="glass-panel" style={{ padding: 20 }}>
          <div className="card-title-row">
            <h2 className="card-title">
              <Shield size={16} style={{ color: 'var(--accent)' }} />
              当前登录信息
            </h2>
          </div>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
            <div className="setting-row">
              <span className="muted-sm">当前成员</span>
              <strong>{principal?.nickname || '-'}</strong>
            </div>
            <div className="setting-row">
              <span className="muted-sm">成员角色</span>
              <span className="tag accent">
                {ROLE_LABELS[principal?.role || ''] || principal?.role || '-'}
              </span>
            </div>
            <div className="setting-row">
              <span className="muted-sm">登录模式</span>
              <span>{principal?.login_mode === 'household' ? '主账号登录' : '独立成员登录'}</span>
            </div>
            <div className="setting-row">
              <span className="muted-sm">家庭组 ID</span>
              <span style={{ fontFamily: 'var(--font-mono)', fontSize: 12 }}>
                {principal?.household_id || '-'}
              </span>
            </div>
            <div className="setting-row">
              <span className="muted-sm">会话有效期至</span>
              <span className="muted-sm">{formatDateTime(principal?.expires_at)}</span>
            </div>
          </div>
        </div>

        {/* Household Settings */}
        <form className="glass-panel" style={{ padding: 20, display: 'flex', flexDirection: 'column', gap: 14 }} onSubmit={handleSaveHousehold}>
          <div className="card-title-row" style={{ marginBottom: 4 }}>
            <h2 className="card-title">
              <Home size={16} style={{ color: 'var(--success)' }} />
              家庭空间资料
            </h2>
          </div>

          <div className="field">
            <label>家庭名称</label>
            <input
              className="input"
              required
              maxLength={64}
              disabled={!canManageSettings || hhBusy}
              value={hhName}
              onChange={(e) => setHhName(e.target.value)}
            />
          </div>

          <div className="field">
            <label>默认显示语言</label>
            <CustomSelect
              value={hhLang}
              onChange={setHhLang}
              options={LANG_OPTIONS}
              disabled={!canManageSettings || hhBusy}
            />
          </div>

          {!canManageSettings ? (
            <div className="muted-sm">当前身份无权限修改家庭空间设置。</div>
          ) : (
            <div className="flex-row" style={{ justifyContent: 'flex-end', marginTop: 'auto' }}>
              <button type="submit" className="btn btn-primary" disabled={hhBusy}>
                {hhBusy ? <Loader2 size={15} className="spin" /> : <Save size={15} />}
                保存资料
              </button>
            </div>
          )}
        </form>
      </div>

      {/* Password Change */}
      <div className="glass-panel" style={{ padding: 20 }}>
        <div className="card-title-row">
          <h2 className="card-title">
            <KeyRound size={16} style={{ color: 'var(--warning)' }} />
            修改主账号密码
          </h2>
        </div>

        {!canChangeAccountPw ? (
          <div className="setting-row">
            <div className="flex-row" style={{ gap: 8 }}>
              <Info size={16} style={{ color: 'var(--accent)', flexShrink: 0 }} />
              <span className="muted-sm">
                仅通过主账号登录的家庭所有者（Owner）可以修改主账号登录密码。
              </span>
            </div>
          </div>
        ) : (
          <form onSubmit={handleChangePassword} style={{ display: 'flex', flexDirection: 'column', gap: 14, maxWidth: 480 }}>
            <div className="setting-row" style={{ borderColor: 'rgba(124, 196, 255, 0.25)' }}>
              <div className="flex-row" style={{ gap: 8, flexWrap: 'nowrap' }}>
                <Info size={16} style={{ color: 'var(--accent)', flexShrink: 0 }} />
                <span className="muted-sm" style={{ lineHeight: 1.5 }}>
                  若你已在 Plezy 客户端开启端到端加密（E2EE）密钥包装，建议通过客户端修改密码，以便同步重封装家庭密钥。
                </span>
              </div>
            </div>

            <div className="field">
              <label>当前密码</label>
              <input
                className="input"
                type="password"
                required
                value={oldPassword}
                onChange={(e) => setOldPassword(e.target.value)}
              />
            </div>
            <div className="field">
              <label>新密码（至少 8 位）</label>
              <input
                className="input"
                type="password"
                required
                minLength={8}
                value={newPassword}
                onChange={(e) => setNewPassword(e.target.value)}
              />
            </div>
            <div className="field">
              <label>确认新密码</label>
              <input
                className="input"
                type="password"
                required
                minLength={8}
                value={confirmPassword}
                onChange={(e) => setConfirmPassword(e.target.value)}
              />
            </div>
            <div className="flex-row">
              <button type="submit" className="btn btn-primary" disabled={pwBusy}>
                {pwBusy ? <Loader2 size={15} className="spin" /> : <KeyRound size={15} />}
                更新登录密码
              </button>
            </div>
          </form>
        )}
      </div>
    </div>
  );
};
