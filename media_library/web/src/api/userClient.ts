import { ApiError } from './client';
import type {
  DeviceView,
  FolderView,
  HouseholdInfo,
  MemberView,
  ScanSessionView,
  SessionView,
  SourceView,
  UserAuthResult,
  UserPrincipal,
} from '../types';

const USER_TOKEN_STORAGE_KEY = 'media_library_user_token';
const WEB_DEVICE_ID_KEY = 'media_library_web_device_id';

export function getUserToken(): string {
  return localStorage.getItem(USER_TOKEN_STORAGE_KEY) || '';
}

export function setUserToken(tok: string): void {
  if (tok) {
    localStorage.setItem(USER_TOKEN_STORAGE_KEY, tok);
  } else {
    localStorage.removeItem(USER_TOKEN_STORAGE_KEY);
  }
}

export function getOrCreateWebDeviceId(): string {
  const existing = localStorage.getItem(WEB_DEVICE_ID_KEY);
  if (existing) return existing;
  const generated =
    typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function'
      ? `web-${crypto.randomUUID()}`
      : `web-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
  localStorage.setItem(WEB_DEVICE_ID_KEY, generated);
  return generated;
}

function detectPlatformAndName(): { platform: string; name: string } {
  const ua = typeof navigator !== 'undefined' ? navigator.userAgent : '';
  let platform = 'Web';
  if (/Windows/i.test(ua)) platform = 'Windows';
  else if (/Macintosh|Mac OS X/i.test(ua)) platform = 'macOS';
  else if (/Android/i.test(ua)) platform = 'Android';
  else if (/iPhone|iPad|iPod/i.test(ua)) platform = 'iOS';
  else if (/Linux/i.test(ua)) platform = 'Linux';

  let browser = 'Browser';
  if (/Edg\//i.test(ua)) browser = 'Edge';
  else if (/Chrome\//i.test(ua)) browser = 'Chrome';
  else if (/Firefox\//i.test(ua)) browser = 'Firefox';
  else if (/Safari\//i.test(ua)) browser = 'Safari';

  return {
    platform,
    name: `${platform} ${browser} 用户面板`,
  };
}

export function getWebDeviceInput() {
  const { platform, name } = detectPlatformAndName();
  return {
    device_id: getOrCreateWebDeviceId(),
    class: 'web',
    platform,
    name,
    app_version: 'web-1.0',
  };
}

async function userRequest<T>(path: string, opts: RequestInit = {}): Promise<T> {
  const token = getUserToken();
  const headers: Record<string, string> = {
    Accept: 'application/json',
    ...(opts.headers as Record<string, string> | undefined),
  };
  if (opts.body && !headers['Content-Type']) {
    headers['Content-Type'] = 'application/json';
  }
  if (token) {
    headers['Authorization'] = `Bearer ${token}`;
  }
  const resp = await fetch(path, { ...opts, headers });
  const text = await resp.text();
  let json: Record<string, unknown> = {};
  try {
    json = text ? (JSON.parse(text) as Record<string, unknown>) : {};
  } catch {
    json = { message: text || `HTTP ${resp.status}` };
  }
  if (!resp.ok) {
    const code = typeof json.error === 'string' ? json.error : `http_${resp.status}`;
    const msg = typeof json.message === 'string' && json.message ? json.message : `请求失败 (${resp.status})`;
    throw new ApiError(resp.status, code, msg);
  }
  return json as T;
}

export const userApi = {
  login: (username: string, password: string) =>
    userRequest<UserAuthResult>('/api/v1/auth/login', {
      method: 'POST',
      body: JSON.stringify({
        username,
        password,
        device: getWebDeviceInput(),
      }),
    }),

  selectMember: (login_ticket: string, member_id: string, pin?: string) =>
    userRequest<UserAuthResult>('/api/v1/auth/select-member', {
      method: 'POST',
      body: JSON.stringify({
        login_ticket,
        member_id,
        pin: pin || undefined,
        device_id: getOrCreateWebDeviceId(),
      }),
    }),

  logout: () => userRequest<{ code: number }>('/api/v1/auth/logout', { method: 'POST' }),

  me: () =>
    userRequest<{
      code: number;
      principal: UserPrincipal;
      household: HouseholdInfo;
      members: MemberView[];
    }>('/api/v1/auth/me'),

  changePassword: (old_password: string, new_password: string) =>
    userRequest<{ code: number }>('/api/v1/auth/change-password', {
      method: 'POST',
      body: JSON.stringify({ old_password, new_password }),
    }),

  updateHousehold: (payload: { name?: string; display_lang?: string }) =>
    userRequest<{ code: number; household: HouseholdInfo }>('/api/v1/household', {
      method: 'PATCH',
      body: JSON.stringify(payload),
    }),

  listDevices: () =>
    userRequest<{ code: number; devices: DeviceView[] }>('/api/v1/household/devices'),

  revokeDevice: (id: string) =>
    userRequest<{ code: number }>(`/api/v1/household/devices/${encodeURIComponent(id)}`, {
      method: 'DELETE',
    }),

  listSessions: () =>
    userRequest<{ code: number; sessions: SessionView[] }>('/api/v1/household/sessions'),

  revokeSession: (tokenId: string) =>
    userRequest<{ code: number }>(`/api/v1/household/sessions/${encodeURIComponent(tokenId)}`, {
      method: 'DELETE',
    }),

  listSources: () =>
    userRequest<{ code: number; sources: SourceView[] }>('/api/v1/sources'),

  updateSource: (id: string, name: string) =>
    userRequest<{ code: number; source: SourceView }>(`/api/v1/sources/${encodeURIComponent(id)}`, {
      method: 'PATCH',
      body: JSON.stringify({ name }),
    }),

  deleteSource: (id: string) =>
    userRequest<{ code: number }>(`/api/v1/sources/${encodeURIComponent(id)}`, {
      method: 'DELETE',
    }),

  listFolders: (sourceId: string) =>
    userRequest<{ code: number; folders: FolderView[] }>(`/api/v1/sources/${encodeURIComponent(sourceId)}/folders`),

  addFolder: (
    sourceId: string,
    payload: { path: string; exclude_paths?: string[]; library_hint?: string },
  ) =>
    userRequest<{ code: number; folder: FolderView }>(`/api/v1/sources/${encodeURIComponent(sourceId)}/folders`, {
      method: 'POST',
      body: JSON.stringify(payload),
    }),

  updateFolder: (
    sourceId: string,
    folderId: string,
    payload: { path?: string; exclude_paths?: string[]; library_hint?: string },
  ) =>
    userRequest<{ code: number; folder: FolderView }>(
      `/api/v1/sources/${encodeURIComponent(sourceId)}/folders/${encodeURIComponent(folderId)}`,
      {
        method: 'PATCH',
        body: JSON.stringify(payload),
      },
    ),

  deleteFolder: (sourceId: string, folderId: string) =>
    userRequest<{ code: number }>(
      `/api/v1/sources/${encodeURIComponent(sourceId)}/folders/${encodeURIComponent(folderId)}`,
      {
        method: 'DELETE',
      },
    ),

  listSourceScanSessions: (sourceId: string) =>
    userRequest<{ code: number; sessions: ScanSessionView[] }>(
      `/api/v1/sources/${encodeURIComponent(sourceId)}/scan-sessions`,
    ),
};
