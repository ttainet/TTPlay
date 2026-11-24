import React from 'react';
import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom';
import { Loader2 } from 'lucide-react';
import { AppShell } from './components/AppShell';
import { BrandLogo } from './components/BrandLogo';
import { ToastStack } from './components/ToastStack';
import { UserShell } from './components/UserShell';
import { AppProvider, useApp } from './contexts/AppContext';
import { UserProvider, useUser } from './contexts/UserContext';
import { AdminAccountsPage } from './pages/AdminAccountsPage';
import { AdminAuditPage } from './pages/AdminAuditPage';
import { AdminInvitesPage } from './pages/AdminInvitesPage';
import { AdminOverviewPage } from './pages/AdminOverviewPage';
import { LoginPage } from './pages/LoginPage';
import { MetadataManagePage } from './pages/MetadataManagePage';
import { ServerLogsPage } from './pages/ServerLogsPage';
import { SettingsPage } from './pages/SettingsPage';
import { UserDevicesPage } from './pages/user/UserDevicesPage';
import { UserLoginPage } from './pages/user/UserLoginPage';
import { UserOverviewPage } from './pages/user/UserOverviewPage';
import { UserSecurityPage } from './pages/user/UserSecurityPage';
import { UserSourcesPage } from './pages/user/UserSourcesPage';

const FullscreenLoader: React.FC<{ label: string }> = ({ label }) => (
  <div className="auth-screen">
    <div className="glass-panel" style={{ padding: '24px 32px', display: 'flex', alignItems: 'center', gap: 14 }}>
      <BrandLogo size={32} />
      <div className="flex-row" style={{ gap: 8 }}>
        <Loader2 size={16} className="spin" style={{ color: 'var(--accent)' }} />
        <span style={{ fontSize: 14, color: 'var(--text-secondary)' }}>{label}</span>
      </div>
    </div>
  </div>
);

const AdminRoutes: React.FC = () => {
  const { loading, admin } = useApp();

  if (loading) {
    return <FullscreenLoader label="正在加载管理控制台..." />;
  }

  if (!admin || admin.must_change_password) {
    return <LoginPage />;
  }

  return (
    <AppShell>
      <Routes>
        <Route index element={<AdminOverviewPage />} />
        <Route path="accounts" element={<AdminAccountsPage />} />
        <Route path="invites" element={<AdminInvitesPage />} />
        <Route path="settings" element={<SettingsPage />} />
        <Route path="metadata" element={<MetadataManagePage />} />
        <Route path="logs" element={<ServerLogsPage />} />
        <Route path="audit" element={<AdminAuditPage />} />
        <Route path="*" element={<Navigate to="/admin" replace />} />
      </Routes>
    </AppShell>
  );
};

const UserLoginRoute: React.FC = () => {
  const { loading, principal } = useUser();

  if (loading) {
    return <FullscreenLoader label="正在校验用户会话..." />;
  }

  if (principal) {
    return <Navigate to="/app" replace />;
  }

  return <UserLoginPage />;
};

const UserRoutes: React.FC = () => {
  const { loading, principal } = useUser();

  if (loading) {
    return <FullscreenLoader label="正在加载用户面板..." />;
  }

  if (!principal) {
    return <Navigate to="/login" replace />;
  }

  return (
    <UserShell>
      <Routes>
        <Route index element={<UserOverviewPage />} />
        <Route path="sources" element={<UserSourcesPage />} />
        <Route path="devices" element={<UserDevicesPage />} />
        <Route path="security" element={<UserSecurityPage />} />
        <Route path="*" element={<Navigate to="/app" replace />} />
      </Routes>
    </UserShell>
  );
};

const RootRedirect: React.FC = () => {
  const { loading: adminLoading, admin } = useApp();
  const { loading: userLoading, principal } = useUser();

  if (adminLoading || userLoading) {
    return <FullscreenLoader label="正在初始化服务..." />;
  }

  if (principal) {
    return <Navigate to="/app" replace />;
  }
  if (admin && !admin.must_change_password) {
    return <Navigate to="/admin" replace />;
  }
  return <Navigate to="/login" replace />;
};

class AppErrorBoundary extends React.Component<
  { children: React.ReactNode },
  { error: Error | null }
> {
  constructor(props: { children: React.ReactNode }) {
    super(props);
    this.state = { error: null };
  }

  static getDerivedStateFromError(error: Error) {
    return { error };
  }

  render() {
    if (this.state.error) {
      return (
        <div className="auth-screen">
          <div className="glass-panel auth-card" style={{ maxWidth: 520 }}>
            <h2 style={{ margin: 0, fontSize: 18, color: 'var(--danger)' }}>页面渲染发生异常</h2>
            <p className="muted" style={{ margin: 0, fontSize: 13, lineHeight: 1.5 }}>
              {this.state.error.message || '未知前端错误'}
            </p>
            <div className="flex-row" style={{ justifyContent: 'flex-end' }}>
              <button type="button" className="btn btn-primary" onClick={() => window.location.reload()}>
                重新加载页面
              </button>
            </div>
          </div>
        </div>
      );
    }
    return this.props.children;
  }
}

export const App: React.FC = () => (
  <AppErrorBoundary>
    <AppProvider>
      <UserProvider>
        <BrowserRouter>
          <Routes>
            <Route path="/admin/*" element={<AdminRoutes />} />
            <Route path="/login" element={<UserLoginRoute />} />
            <Route path="/app/*" element={<UserRoutes />} />
            <Route path="/" element={<RootRedirect />} />
            <Route path="*" element={<RootRedirect />} />
          </Routes>
          <ToastStack />
        </BrowserRouter>
      </UserProvider>
    </AppProvider>
  </AppErrorBoundary>
);

export default App;
