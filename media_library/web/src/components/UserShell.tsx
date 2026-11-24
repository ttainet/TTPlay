import React, { useState } from 'react';
import { NavLink, useLocation } from 'react-router-dom';
import {
  FolderCog,
  Home,
  LayoutDashboard,
  LogOut,
  MonitorSmartphone,
  PanelLeftClose,
  PanelLeftOpen,
  Shield,
} from 'lucide-react';
import { useApp } from '../contexts/AppContext';
import { useUser } from '../contexts/UserContext';
import { ROLE_LABELS } from '../utils/userPerms';
import { BrandLogo } from './BrandLogo';

const USER_ROUTE_TITLES: Record<string, { title: string; subtitle: string }> = {
  '/app': { title: '我的概览', subtitle: '查看家庭媒体空间、配额使用与设备活跃状态' },
  '/app/sources': { title: '媒体源管理', subtitle: '管理已添加的网盘与媒体服务器、扫描目录及同步记录' },
  '/app/devices': { title: '设备与会话', subtitle: '查看已登录终端设备、在线会话并管理访问授权' },
  '/app/security': { title: '账号与安全', subtitle: '配置家庭基本信息与修改登录密码' },
  // Future Phase 2 routes reserved:
  // '/app/family': { title: '家庭组与成员', subtitle: '管理家庭成员档案、独立账号与成员 PIN' },
  // '/app/permissions': { title: '权限与分级', subtitle: '配置成员角色、权限掩码、可见媒体源与内容分级' },
};

export const UserShell: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  const { bootstrap } = useApp();
  const { principal, household, userLogout } = useUser();
  const location = useLocation();
  const [collapsed, setCollapsed] = useState(false);

  const serverTitle = bootstrap?.server_name || 'TTPlay Media';
  const routeMeta = USER_ROUTE_TITLES[location.pathname] || USER_ROUTE_TITLES['/app'];
  const roleLabel = ROLE_LABELS[principal?.role || 'member'] || principal?.role || '成员';

  return (
    <div className="app-shell">
      <aside className={`sidebar ${collapsed ? 'collapsed' : ''}`}>
        <div className="brand-row">
          <NavLink to="/app" className="brand-logo" title={serverTitle}>
            <BrandLogo size={32} alt={serverTitle} />
            <span className="brand-title">{serverTitle}</span>
          </NavLink>
          <button
            type="button"
            className="btn btn-icon"
            style={{ width: 30, height: 30, padding: 0 }}
            onClick={() => setCollapsed((v) => !v)}
            title={collapsed ? '展开侧边栏' : '收起侧边栏'}
          >
            {collapsed ? <PanelLeftOpen size={15} /> : <PanelLeftClose size={15} />}
          </button>
        </div>

        <div className="sidebar-scroll">
          <div>
            <div className="nav-group-label">我的空间</div>
            <nav className="nav-list">
              <NavLink to="/app" end className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`} title="我的概览">
                <LayoutDashboard size={18} />
                <span className="nav-text">我的概览</span>
              </NavLink>
              <NavLink to="/app/sources" className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`} title="媒体源管理">
                <FolderCog size={18} />
                <span className="nav-text">媒体源管理</span>
              </NavLink>
              <NavLink to="/app/devices" className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`} title="设备与会话">
                <MonitorSmartphone size={18} />
                <span className="nav-text">设备与会话</span>
              </NavLink>
            </nav>
          </div>

          <div>
            <div className="nav-group-label">账号设置</div>
            <nav className="nav-list">
              <NavLink to="/app/security" className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`} title="账号与安全">
                <Shield size={18} />
                <span className="nav-text">账号与安全</span>
              </NavLink>
            </nav>
          </div>
          {/* Future Phase 2 navigation group reserved for /app/family and /app/permissions */}
        </div>

        <div className="sidebar-footer">
          <div className="flex-row sidebar-user-meta" style={{ gap: 10, minWidth: 0, flexWrap: 'nowrap' }}>
            <span className="avatar-circle" style={{ width: 30, height: 30, fontSize: 12 }}>
              {(principal?.nickname || 'U').slice(0, 1)}
            </span>
            <div style={{ minWidth: 0 }}>
              <div style={{ fontSize: 13, fontWeight: 600, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                {principal?.nickname || '用户'}
              </div>
              <div className="muted-sm" style={{ fontSize: 11 }}>
                {roleLabel}
              </div>
            </div>
          </div>
          <button
            type="button"
            className="btn btn-icon"
            style={{ width: 32, height: 32, padding: 0 }}
            title="退出用户面板"
            onClick={() => void userLogout()}
          >
            <LogOut size={15} />
          </button>
        </div>
      </aside>

      <div className="main-area">
        <header className="topbar">
          <div style={{ display: 'flex', alignItems: 'center', gap: 12, minWidth: 0 }}>
            <div style={{ minWidth: 0 }}>
              <div style={{ fontSize: 15, fontWeight: 700, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
                {routeMeta.title}
              </div>
              <div className="muted-sm" style={{ whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
                {routeMeta.subtitle}
              </div>
            </div>
          </div>

          <div className="topbar-right">
            {household && (
              <span className="privacy-pill" title={`家庭组 ID: ${household.id}`}>
                <Home size={13} />
                <span>{household.name}</span>
              </span>
            )}
            <span className="tag accent">{roleLabel}</span>
          </div>
        </header>

        <main className="page-content">{children}</main>
      </div>

      <nav className="mobile-dock">
        <NavLink to="/app" end className={({ isActive }) => `mobile-dock-item ${isActive ? 'active' : ''}`}>
          <LayoutDashboard size={18} />
          <span>概览</span>
        </NavLink>
        <NavLink to="/app/sources" className={({ isActive }) => `mobile-dock-item ${isActive ? 'active' : ''}`}>
          <FolderCog size={18} />
          <span>媒体源</span>
        </NavLink>
        <NavLink to="/app/devices" className={({ isActive }) => `mobile-dock-item ${isActive ? 'active' : ''}`}>
          <MonitorSmartphone size={18} />
          <span>设备</span>
        </NavLink>
        <NavLink to="/app/security" className={({ isActive }) => `mobile-dock-item ${isActive ? 'active' : ''}`}>
          <Shield size={18} />
          <span>安全</span>
        </NavLink>
      </nav>
    </div>
  );
};
