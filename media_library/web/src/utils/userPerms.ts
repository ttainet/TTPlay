import type { UserPrincipal } from '../types';

export const UserPerm = {
  Browse: 1 << 0,
  UploadFacts: 1 << 1,
  ManageSources: 1 << 2,
  ManageMembers: 1 << 3,
  ManageSettings: 1 << 4,
  DeleteHousehold: 1 << 5,
} as const;

export function hasUserPerm(principal: UserPrincipal | null | undefined, perm: number): boolean {
  if (!principal) return false;
  if (principal.role === 'owner') return true;
  return (principal.permissions & perm) === perm;
}

export const SOURCE_KINDS_WITH_FOLDERS = new Set(['quark', 'webdav', 'smb']);

export const SOURCE_KIND_LABELS: Record<string, string> = {
  quark: '夸克网盘',
  webdav: 'WebDAV',
  smb: 'SMB 共享',
  emby: 'Emby',
  jellyfin: 'Jellyfin',
  iptv: 'IPTV',
};

export const LIBRARY_HINT_LABELS: Record<string, string> = {
  auto: '自动识别',
  movie: '电影',
  show: '剧集',
  anime: '动漫',
  variety: '综艺',
  documentary: '纪录片',
};

export const LIBRARY_HINT_OPTIONS = Object.entries(LIBRARY_HINT_LABELS).map(([value, label]) => ({
  value,
  label,
}));

export const DEVICE_CLASS_LABELS: Record<string, string> = {
  desktop: '桌面端',
  phone: '手机',
  tablet: '平板',
  tv: '电视端',
  web: 'Web 浏览器',
};

export const ROLE_LABELS: Record<string, string> = {
  owner: '家庭所有者',
  admin: '管理员',
  member: '家庭成员',
  child: '儿童成员',
};

export const CREDENTIAL_STATUS_LABELS: Record<string, { label: string; tagClass: string }> = {
  valid: { label: '凭据有效', tagClass: 'success' },
  expired: { label: '已过期', tagClass: 'gold' },
  kicked: { label: '已失效/被踢下线', tagClass: 'danger' },
};

export const SCAN_STATUS_LABELS: Record<string, { label: string; tagClass: string }> = {
  running: { label: '扫描中', tagClass: 'accent' },
  completed: { label: '已完成', tagClass: 'success' },
  partial: { label: '部分完成', tagClass: 'gold' },
  stale: { label: '已超时中断', tagClass: 'danger' },
};
