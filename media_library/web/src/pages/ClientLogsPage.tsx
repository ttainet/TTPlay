import React, { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Calendar,
  ChevronLeft,
  ChevronRight,
  Copy,
  Download,
  Eye,
  FileWarning,
  Laptop,
  Loader2,
  MonitorSmartphone,
  RefreshCw,
  RotateCcw,
  Search,
  Smartphone,
  Trash2,
  Tv,
  X,
} from 'lucide-react';
import { api, formatBytes, formatDateTime } from '../api/client';
import { CustomSelect, type SelectOption } from '../components/CustomSelect';
import { ModalBackdrop } from '../components/ModalBackdrop';
import { TableSkeleton } from '../components/Skeletons';
import { useApp } from '../contexts/AppContext';
import type { ClientLogDetail, ClientLogSummary } from '../types';

const PAGE_SIZE = 25;

type PlatformChipId = 'all' | 'android' | 'tv' | 'windows' | 'macos' | 'ios' | 'linux';
type DatePresetId = 'all' | 'today' | '3d' | '7d' | '30d' | 'custom';
type DetailLevelFilter = 'ALL' | 'WARN_ERR' | 'INFO' | 'DEBUG';

const PLATFORM_CHIPS: Array<{ id: PlatformChipId; label: string }> = [
  { id: 'all', label: '全部端' },
  { id: 'android', label: 'Android' },
  { id: 'tv', label: '仅 TV' },
  { id: 'windows', label: 'Windows' },
  { id: 'macos', label: 'macOS' },
  { id: 'ios', label: 'iOS' },
  { id: 'linux', label: 'Linux' },
];

const PLATFORM_LABELS: Record<string, string> = {
  android: 'Android',
  windows: 'Windows',
  macos: 'macOS',
  ios: 'iOS',
  linux: 'Linux',
  unknown: '未知',
};

function toLocalDateStr(d: Date): string {
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

function getDateRangeForPreset(preset: Exclude<DatePresetId, 'custom'>): { from: string; to: string } {
  if (preset === 'all') return { from: '', to: '' };
  const now = new Date();
  const to = toLocalDateStr(now);
  const offsetDays = preset === 'today' ? 0 : preset === '3d' ? 2 : preset === '7d' ? 6 : 29;
  const start = new Date(now.getFullYear(), now.getMonth(), now.getDate() - offsetDays);
  return { from: toLocalDateStr(start), to };
}

function PlatformIcon({ platform, isTv }: { platform: string; isTv: boolean }) {
  if (isTv) return <Tv size={14} style={{ color: 'var(--accent)' }} />;
  switch (platform) {
    case 'android':
    case 'ios':
      return <Smartphone size={14} />;
    case 'windows':
    case 'macos':
    case 'linux':
      return <Laptop size={14} />;
    default:
      return <MonitorSmartphone size={14} />;
  }
}

function classifyLogLine(line: string): { level: 'ERROR' | 'WARN' | 'INFO' | 'DEBUG' | 'OTHER'; color: string } {
  const upper = line.toUpperCase();
  if (upper.includes('[ERROR]') || upper.includes('[FATAL]') || upper.startsWith('ERROR:')) {
    return { level: 'ERROR', color: 'var(--danger)' };
  }
  if (upper.includes('[WARNING]') || upper.includes('[WARN]')) {
    return { level: 'WARN', color: 'var(--warning)' };
  }
  if (upper.includes('[INFO]')) {
    return { level: 'INFO', color: 'var(--accent)' };
  }
  if (upper.includes('[DEBUG]') || upper.includes('[TRACE]')) {
    return { level: 'DEBUG', color: 'var(--text-secondary)' };
  }
  return { level: 'OTHER', color: 'var(--text-primary)' };
}

export const ClientLogsPage: React.FC = () => {
  const { toast } = useApp();

  const [items, setItems] = useState<ClientLogSummary[]>([]);
  const [total, setTotal] = useState(0);
  const [totalBytes, setTotalBytes] = useState(0);
  const [devices, setDevices] = useState<string[]>([]);
  const [loading, setLoading] = useState(true);

  const [platformChip, setPlatformChip] = useState<PlatformChipId>('all');
  const [selectedDevice, setSelectedDevice] = useState('');
  const [datePreset, setDatePreset] = useState<DatePresetId>('all');
  const [dateFrom, setDateFrom] = useState('');
  const [dateTo, setDateTo] = useState('');
  const [keywordInput, setKeywordInput] = useState('');
  const [activeKeyword, setActiveKeyword] = useState('');
  const [page, setPage] = useState(0);

  const [detailLoadingId, setDetailLoadingId] = useState<string | null>(null);
  const [detailModal, setDetailModal] = useState<ClientLogDetail | null>(null);
  const [detailLevel, setDetailLevel] = useState<DetailLevelFilter>('ALL');
  const [detailQuery, setDetailQuery] = useState('');

  const [pruneModalOpen, setPruneModalOpen] = useState(false);
  const [pruning, setPruning] = useState(false);

  // Debounce keyword input so typing searches smoothly without an explicit submit requirement
  useEffect(() => {
    const timer = window.setTimeout(() => {
      const next = keywordInput.trim();
      setActiveKeyword((prev) => {
        if (prev !== next) setPage(0);
        return next;
      });
    }, 250);
    return () => window.clearTimeout(timer);
  }, [keywordInput]);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const res = await api.listClientLogs({
        device: selectedDevice || undefined,
        platform: platformChip === 'all' || platformChip === 'tv' ? undefined : platformChip,
        is_tv: platformChip === 'tv' ? true : undefined,
        date_from: dateFrom || undefined,
        date_to: dateTo || undefined,
        tz_offset: new Date().getTimezoneOffset(),
        q: activeKeyword || undefined,
        limit: PAGE_SIZE,
        offset: page * PAGE_SIZE,
      });
      setItems(res.items || []);
      setTotal(res.total || 0);
      setTotalBytes(res.total_size_bytes || 0);
      setDevices(res.devices || []);
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setLoading(false);
    }
  }, [activeKeyword, dateFrom, dateTo, page, platformChip, selectedDevice, toast]);

  useEffect(() => {
    void load();
  }, [load]);

  const deviceOptions = useMemo<Array<SelectOption<string>>>(() => {
    const list: Array<SelectOption<string>> = [{ value: '', label: '全部设备' }];
    const seen = new Set<string>();
    for (const dev of devices) {
      if (!dev || seen.has(dev)) continue;
      seen.add(dev);
      list.push({ value: dev, label: dev });
    }
    if (selectedDevice && !seen.has(selectedDevice)) {
      list.push({ value: selectedDevice, label: selectedDevice });
    }
    return list;
  }, [devices, selectedDevice]);

  const applyDatePreset = (preset: Exclude<DatePresetId, 'custom'>) => {
    const { from, to } = getDateRangeForPreset(preset);
    setDatePreset(preset);
    setDateFrom(from);
    setDateTo(to);
    setPage(0);
  };

  const resetFilters = () => {
    setPlatformChip('all');
    setSelectedDevice('');
    setDatePreset('all');
    setDateFrom('');
    setDateTo('');
    setKeywordInput('');
    setActiveKeyword('');
    setPage(0);
  };

  const handleCopy = async (text: string, label: string) => {
    try {
      await navigator.clipboard.writeText(text);
      toast(`已复制${label}`, 'success');
    } catch {
      toast('复制失败，请检查浏览器剪贴板权限', 'error');
    }
  };

  const handleOpenDetail = async (id: string) => {
    setDetailLoadingId(id);
    try {
      const res = await api.getClientLog(id);
      setDetailLevel('ALL');
      setDetailQuery('');
      setDetailModal(res.log);
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setDetailLoadingId(null);
    }
  };

  const handleDownload = async (summary: Pick<ClientLogSummary, 'id' | 'created_date'>) => {
    try {
      const blob = await api.downloadClientLogBlob(summary.id);
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = `ttplay-log-${summary.id}-${summary.created_date || 'log'}.log`;
      a.click();
      URL.revokeObjectURL(url);
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  };

  const handleDelete = async (id: string) => {
    if (!window.confirm(`确定删除客户端日志 ${id} 吗？`)) return;
    try {
      await api.deleteClientLog(id);
      toast(`已删除日志 ${id}`, 'success');
      if (detailModal?.id === id) {
        setDetailModal(null);
      }
      await load();
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  };

  const handlePrune = async (payload: { older_than_days?: number; device?: string; all?: boolean }, confirmText: string) => {
    if (pruning) return;
    if (!window.confirm(confirmText)) return;
    setPruning(true);
    try {
      const res = await api.pruneClientLogs(payload);
      toast(`已清理 ${res.deleted} 条客户端日志`, 'success');
      setPruneModalOpen(false);
      setPage(0);
      await load();
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setPruning(false);
    }
  };

  const filteredDetailLines = useMemo(() => {
    if (!detailModal) return [];
    const rawLines = detailModal.content.replace(/\r\n/g, '\n').split('\n');
    const qLower = detailQuery.trim().toLowerCase();
    const out: Array<{ lineNo: number; text: string; color: string }> = [];
    for (let i = 0; i < rawLines.length; i++) {
      const text = rawLines[i];
      const cls = classifyLogLine(text);
      if (detailLevel === 'WARN_ERR' && cls.level !== 'ERROR' && cls.level !== 'WARN') continue;
      if (detailLevel === 'INFO' && cls.level !== 'INFO') continue;
      if (detailLevel === 'DEBUG' && cls.level !== 'DEBUG') continue;
      if (qLower && !text.toLowerCase().includes(qLower)) continue;
      out.push({ lineNo: i + 1, text, color: cls.color });
    }
    return out;
  }, [detailLevel, detailModal, detailQuery]);

  const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE));
  const hasFilters = Boolean(
    platformChip !== 'all' || selectedDevice || dateFrom || dateTo || activeKeyword
  );

  return (
    <div className="page-stack">
      <div className="page-header">
        <div>
          <h1 className="page-title">客户端上报日志</h1>
          <p className="page-subtitle">
            收集客户端一键上传的诊断日志与启动故障报告，支持按设备、日期和日志 ID 筛选排查（自动保留最近 30 天内最多 500 条）。
          </p>
        </div>
        <div className="flex-row" style={{ gap: 8 }}>
          <span className="tag">
            共 {total} 条 · {formatBytes(totalBytes)}
          </span>
          <button type="button" className="btn btn-sm" onClick={() => void load()} disabled={loading}>
            <RefreshCw size={13} className={loading ? 'spin' : ''} /> 刷新
          </button>
          <button type="button" className="btn btn-danger btn-sm" onClick={() => setPruneModalOpen(true)}>
            <Trash2 size={13} /> 批量清理
          </button>
        </div>
      </div>

      {/* Filter Bar */}
      <div className="card-box" style={{ padding: 16, display: 'flex', flexDirection: 'column', gap: 12 }}>
        <div className="flex-row" style={{ justifyContent: 'space-between', gap: 10 }}>
          <div className="flex-row" style={{ gap: 6 }}>
            <span className="muted-sm" style={{ marginRight: 2 }}>
              平台：
            </span>
            {PLATFORM_CHIPS.map((c) => (
              <button
                key={c.id}
                type="button"
                className={`chip ${platformChip === c.id ? 'active' : ''}`}
                onClick={() => {
                  setPlatformChip(c.id);
                  setPage(0);
                }}
              >
                {c.label}
              </button>
            ))}
          </div>

          <div className="flex-row" style={{ gap: 8 }}>
            <span className="muted-sm">设备：</span>
            <CustomSelect
              compact
              value={selectedDevice}
              onChange={(val) => {
                setSelectedDevice(val);
                setPage(0);
              }}
              options={deviceOptions}
              minMenuWidth={200}
              style={{ minWidth: 180 }}
            />
          </div>
        </div>

        <div className="flex-row" style={{ justifyContent: 'space-between', gap: 10 }}>
          <div className="flex-row" style={{ gap: 6 }}>
            <Calendar size={14} className="muted" />
            <span className="muted-sm" style={{ marginRight: 2 }}>
              日期：
            </span>
            {(
              [
                { id: 'all', label: '全部日期' },
                { id: 'today', label: '今天' },
                { id: '3d', label: '近 3 天' },
                { id: '7d', label: '近 7 天' },
                { id: '30d', label: '近 30 天' },
              ] as const
            ).map((p) => (
              <button
                key={p.id}
                type="button"
                className={`chip ${datePreset === p.id ? 'active' : ''}`}
                onClick={() => applyDatePreset(p.id)}
              >
                {p.label}
              </button>
            ))}
            <input
              type="date"
              className="input"
              style={{ width: 142, padding: '5px 8px', fontSize: 12.5 }}
              value={dateFrom}
              max={dateTo || undefined}
              onChange={(e) => {
                setDatePreset('custom');
                setDateFrom(e.target.value);
                setPage(0);
              }}
              title="开始日期"
            />
            <span className="muted-sm">至</span>
            <input
              type="date"
              className="input"
              style={{ width: 142, padding: '5px 8px', fontSize: 12.5 }}
              value={dateTo}
              min={dateFrom || undefined}
              onChange={(e) => {
                setDatePreset('custom');
                setDateTo(e.target.value);
                setPage(0);
              }}
              title="结束日期"
            />
          </div>

          <div className="flex-row" style={{ gap: 8, flex: 1, justifyContent: 'flex-end', minWidth: 240 }}>
            <form
              className="search-pill"
              style={{ maxWidth: 320, padding: '5px 12px' }}
              onSubmit={(e) => {
                e.preventDefault();
                setActiveKeyword(keywordInput.trim());
                setPage(0);
              }}
            >
              <Search size={14} className="muted" />
              <input
                type="search"
                style={{ fontSize: 13 }}
                placeholder="搜索日志 ID、设备、版本或正文..."
                value={keywordInput}
                onChange={(e) => setKeywordInput(e.target.value)}
              />
            </form>
            {hasFilters && (
              <button type="button" className="btn btn-sm" onClick={resetFilters} title="清空全部筛选">
                <RotateCcw size={13} /> 重置
              </button>
            )}
          </div>
        </div>
      </div>

      {/* Log List */}
      <div className="card-box" style={{ padding: 16 }}>
        {loading && items.length === 0 ? (
          <TableSkeleton rows={8} />
        ) : items.length === 0 ? (
          <div className="empty-state">
            <MonitorSmartphone size={28} />
            <div style={{ fontSize: 14, color: 'var(--text-secondary)' }}>暂无匹配的客户端上报日志</div>
            <div className="muted-sm">
              {hasFilters ? '可尝试放宽设备、日期或关键字筛选条件' : '当用户在客户端点击「上传日志」后，日志会出现在此处'}
            </div>
          </div>
        ) : (
          <div className="table-wrap">
            <table className="data-table">
              <thead>
                <tr>
                  <th>日志 ID</th>
                  <th>上报时间</th>
                  <th>设备</th>
                  <th>系统 / 版本</th>
                  <th>大小</th>
                  <th>首条异常 / 摘要</th>
                  <th style={{ textAlign: 'right' }}>操作</th>
                </tr>
              </thead>
              <tbody>
                {items.map((item) => (
                  <tr key={item.id}>
                    <td style={{ whiteSpace: 'nowrap' }}>
                      <button
                        type="button"
                        className="chip"
                        style={{ fontFamily: 'var(--font-mono)', fontSize: 12, padding: '3px 8px' }}
                        onClick={() => void handleCopy(item.id, '日志 ID')}
                        title="点击复制日志 ID"
                      >
                        {item.id}
                        <Copy size={11} />
                      </button>
                    </td>
                    <td style={{ whiteSpace: 'nowrap', fontVariantNumeric: 'tabular-nums' }}>
                      {formatDateTime(item.created_at)}
                    </td>
                    <td>
                      <div className="flex-row" style={{ gap: 6 }}>
                        <PlatformIcon platform={item.platform} isTv={item.is_tv} />
                        <span style={{ fontWeight: 600 }}>{item.device_name || '未知设备'}</span>
                        {item.is_tv && <span className="tag accent">TV</span>}
                        {item.source === 'startup_failure' && (
                          <span className="tag danger" title="启动阶段崩溃报告">
                            <FileWarning size={11} /> 启动失败
                          </span>
                        )}
                      </div>
                      {item.client_ip && (
                        <div className="muted-sm" style={{ fontFamily: 'var(--font-mono)', fontSize: 11, marginTop: 2 }}>
                          {item.client_ip}
                        </div>
                      )}
                    </td>
                    <td>
                      <div style={{ fontSize: 12.5 }}>
                        <span className="tag">{PLATFORM_LABELS[item.platform] || item.platform}</span>
                        {item.app_version && (
                          <span className="muted-sm" style={{ marginLeft: 6, fontFamily: 'var(--font-mono)' }}>
                            v{item.app_version}
                          </span>
                        )}
                      </div>
                      {item.os_version && (
                        <div className="muted-sm" style={{ fontSize: 11.5, marginTop: 2 }}>
                          {item.os_version}
                        </div>
                      )}
                    </td>
                    <td style={{ whiteSpace: 'nowrap', fontSize: 12.5 }}>
                      <div>{formatBytes(item.size_bytes)}</div>
                      <div className="muted-sm" style={{ fontSize: 11 }}>
                        {item.line_count} 行
                      </div>
                    </td>
                    <td style={{ maxWidth: 360 }}>
                      <div
                        style={{
                          fontFamily: 'var(--font-mono)',
                          fontSize: 12,
                          color: item.preview.toUpperCase().includes('ERROR')
                            ? 'var(--danger)'
                            : item.preview.toUpperCase().includes('WARN')
                            ? 'var(--warning)'
                            : 'var(--text-secondary)',
                          overflow: 'hidden',
                          textOverflow: 'ellipsis',
                          whiteSpace: 'nowrap',
                        }}
                        title={item.preview}
                      >
                        {item.preview || '-'}
                      </div>
                    </td>
                    <td style={{ textAlign: 'right', whiteSpace: 'nowrap' }}>
                      <div className="flex-row" style={{ justifyContent: 'flex-end', gap: 6 }}>
                        <button
                          type="button"
                          className="btn btn-sm"
                          disabled={detailLoadingId === item.id}
                          onClick={() => void handleOpenDetail(item.id)}
                        >
                          {detailLoadingId === item.id ? (
                            <Loader2 size={13} className="spin" />
                          ) : (
                            <Eye size={13} />
                          )}
                          查看
                        </button>
                        <button
                          type="button"
                          className="btn btn-icon btn-sm"
                          style={{ width: 30, height: 30, padding: 0 }}
                          title="下载 .log 文件"
                          onClick={() => void handleDownload(item)}
                        >
                          <Download size={13} />
                        </button>
                        <button
                          type="button"
                          className="btn btn-danger btn-icon btn-sm"
                          style={{ width: 30, height: 30, padding: 0 }}
                          title="删除此日志"
                          onClick={() => void handleDelete(item.id)}
                        >
                          <Trash2 size={13} />
                        </button>
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}

        {total > PAGE_SIZE && (
          <div className="flex-row" style={{ justifyContent: 'space-between', marginTop: 14, paddingTop: 12, borderTop: '1px solid var(--border-subtle)' }}>
            <span className="muted-sm">
              第 {page + 1} / {totalPages} 页 · 共 {total} 条
            </span>
            <div className="flex-row" style={{ gap: 8 }}>
              <button
                type="button"
                className="btn btn-sm"
                disabled={page === 0 || loading}
                onClick={() => setPage((p) => Math.max(0, p - 1))}
              >
                <ChevronLeft size={14} /> 上一页
              </button>
              <button
                type="button"
                className="btn btn-sm"
                disabled={page + 1 >= totalPages || loading}
                onClick={() => setPage((p) => p + 1)}
              >
                下一页 <ChevronRight size={14} />
              </button>
            </div>
          </div>
        )}
      </div>

      {/* Log Detail Modal */}
      {detailModal && (
        <ModalBackdrop onClose={() => setDetailModal(null)}>
          <div className="modal-panel" style={{ maxWidth: 960 }}>
            <div className="modal-header">
              <div className="flex-row" style={{ gap: 10 }}>
                <h3>客户端日志详情</h3>
                <button
                  type="button"
                  className="chip active"
                  style={{ fontFamily: 'var(--font-mono)', fontSize: 12 }}
                  onClick={() => void handleCopy(detailModal.id, '日志 ID')}
                  title="点击复制日志 ID"
                >
                  {detailModal.id}
                  <Copy size={11} />
                </button>
                {detailModal.is_tv && <span className="tag accent">TV</span>}
                {detailModal.source === 'startup_failure' && <span className="tag danger">启动失败</span>}
              </div>
              <button type="button" className="btn btn-icon btn-sm" onClick={() => setDetailModal(null)}>
                <X size={15} />
              </button>
            </div>

            <div className="modal-body" style={{ gap: 12 }}>
              <div
                className="card-box"
                style={{
                  padding: '12px 14px',
                  display: 'grid',
                  gridTemplateColumns: 'repeat(auto-fit, minmax(170px, 1fr))',
                  gap: 10,
                  fontSize: 12.5,
                }}
              >
                <div>
                  <div className="muted-sm">设备</div>
                  <div style={{ fontWeight: 600, marginTop: 2 }}>{detailModal.device_name || '-'}</div>
                </div>
                <div>
                  <div className="muted-sm">平台 / 系统</div>
                  <div style={{ marginTop: 2 }}>
                    {PLATFORM_LABELS[detailModal.platform] || detailModal.platform}
                    {detailModal.os_version ? ` · ${detailModal.os_version}` : ''}
                  </div>
                </div>
                <div>
                  <div className="muted-sm">客户端版本</div>
                  <div style={{ fontFamily: 'var(--font-mono)', marginTop: 2 }}>
                    {detailModal.app_version || '-'}
                  </div>
                </div>
                <div>
                  <div className="muted-sm">上报时间 / IP</div>
                  <div style={{ marginTop: 2 }}>
                    {formatDateTime(detailModal.created_at)}
                    {detailModal.client_ip ? ` · ${detailModal.client_ip}` : ''}
                  </div>
                </div>
              </div>

              <div className="flex-row" style={{ justifyContent: 'space-between', gap: 10 }}>
                <div className="flex-row" style={{ gap: 6 }}>
                  {(
                    [
                      { id: 'ALL', label: '全部行' },
                      { id: 'WARN_ERR', label: '仅警告/错误' },
                      { id: 'INFO', label: 'INFO' },
                      { id: 'DEBUG', label: 'DEBUG' },
                    ] as const
                  ).map((lv) => (
                    <button
                      key={lv.id}
                      type="button"
                      className={`chip ${detailLevel === lv.id ? 'active' : ''}`}
                      onClick={() => setDetailLevel(lv.id)}
                    >
                      {lv.label}
                    </button>
                  ))}
                  <span className="muted-sm" style={{ marginLeft: 4 }}>
                    显示 {filteredDetailLines.length} / {detailModal.line_count} 行 · {formatBytes(detailModal.size_bytes)}
                  </span>
                </div>

                <div className="search-pill" style={{ maxWidth: 260, padding: '4px 10px' }}>
                  <Search size={13} className="muted" />
                  <input
                    type="search"
                    style={{ fontSize: 12.5 }}
                    placeholder="在日志正文中过滤..."
                    value={detailQuery}
                    onChange={(e) => setDetailQuery(e.target.value)}
                  />
                </div>
              </div>

              <div className="log-terminal" style={{ height: 'min(52vh, 520px)' }}>
                {filteredDetailLines.length === 0 ? (
                  <div className="empty-state" style={{ height: '100%' }}>
                    <div className="muted-sm">当前过滤条件下无匹配行</div>
                  </div>
                ) : (
                  filteredDetailLines.map((line) => (
                    <div
                      key={line.lineNo}
                      style={{
                        display: 'grid',
                        gridTemplateColumns: '48px 1fr',
                        gap: 10,
                        padding: '2px 4px',
                        borderBottom: '1px solid rgba(255, 255, 255, 0.03)',
                      }}
                    >
                      <span className="muted-sm" style={{ textAlign: 'right', userSelect: 'none', fontVariantNumeric: 'tabular-nums' }}>
                        {line.lineNo}
                      </span>
                      <span style={{ color: line.color, whiteSpace: 'pre-wrap', wordBreak: 'break-word' }}>
                        {line.text || ' '}
                      </span>
                    </div>
                  ))
                )}
              </div>
            </div>

            <div className="modal-footer" style={{ justifyContent: 'space-between' }}>
              <button
                type="button"
                className="btn btn-danger btn-sm"
                onClick={() => void handleDelete(detailModal.id)}
              >
                <Trash2 size={14} /> 删除
              </button>
              <div className="flex-row" style={{ gap: 8 }}>
                <button
                  type="button"
                  className="btn btn-sm"
                  onClick={() => void handleCopy(detailModal.content, '完整日志内容')}
                >
                  <Copy size={14} /> 复制全文
                </button>
                <button type="button" className="btn btn-sm" onClick={() => void handleDownload(detailModal)}>
                  <Download size={14} /> 下载 .log
                </button>
                <button type="button" className="btn btn-primary btn-sm" onClick={() => setDetailModal(null)}>
                  关闭
                </button>
              </div>
            </div>
          </div>
        </ModalBackdrop>
      )}

      {/* Batch Prune Modal */}
      {pruneModalOpen && (
        <ModalBackdrop onClose={() => !pruning && setPruneModalOpen(false)}>
          <div className="modal-panel" style={{ maxWidth: 460 }}>
            <div className="modal-header">
              <h3>批量清理客户端日志</h3>
              <button type="button" className="btn btn-icon btn-sm" onClick={() => !pruning && setPruneModalOpen(false)}>
                <X size={15} />
              </button>
            </div>
            <div className="modal-body" style={{ gap: 10 }}>
              <p style={{ margin: 0, fontSize: 13.5, color: 'var(--text-secondary)', lineHeight: 1.6 }}>
                选择要清理的历史日志范围。此操作不可恢复。
              </p>
              <button
                type="button"
                className="btn"
                disabled={pruning}
                style={{ justifyContent: 'space-between' }}
                onClick={() => void handlePrune({ older_than_days: 30 }, '确认删除 30 天前的客户端日志吗？')}
              >
                <span>清理 30 天前的日志</span>
                <span className="muted-sm">保留近 30 天</span>
              </button>
              <button
                type="button"
                className="btn"
                disabled={pruning}
                style={{ justifyContent: 'space-between' }}
                onClick={() => void handlePrune({ older_than_days: 7 }, '确认删除 7 天前的客户端日志吗？')}
              >
                <span>清理 7 天前的日志</span>
                <span className="muted-sm">保留近 7 天</span>
              </button>
              {selectedDevice && (
                <button
                  type="button"
                  className="btn"
                  disabled={pruning}
                  style={{ justifyContent: 'space-between' }}
                  onClick={() =>
                    void handlePrune(
                      { device: selectedDevice },
                      `确认删除设备「${selectedDevice}」的全部上报日志吗？`
                    )
                  }
                >
                  <span>清空当前筛选设备日志</span>
                  <span className="tag">{selectedDevice}</span>
                </button>
              )}
              <button
                type="button"
                className="btn btn-danger"
                disabled={pruning}
                style={{ justifyContent: 'space-between' }}
                onClick={() => void handlePrune({ all: true }, '确认清空全部客户端上报日志吗？此操作无法撤销！')}
              >
                <span>清空全部客户端日志</span>
                {pruning ? <Loader2 size={14} className="spin" /> : <Trash2 size={14} />}
              </button>
            </div>
            <div className="modal-footer">
              <button type="button" className="btn" disabled={pruning} onClick={() => setPruneModalOpen(false)}>
                取消
              </button>
            </div>
          </div>
        </ModalBackdrop>
      )}
    </div>
  );
};
