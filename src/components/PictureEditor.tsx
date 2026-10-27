// Chooses, previews, crops and saves one picture (profile photo, store logo or cover). The preview is the saved
// frame: the same crop is used for both, so what the user sees is what is stored.
import { ChangeEvent, useEffect, useRef, useState } from 'react';
import { ImagePlus, Trash2 } from 'lucide-react';
import { useI18n } from '../i18n';
import { checkImageFile, decodeImage, DEFAULT_CROP, drawFrame, FRAMES, type CropState, type FrameName } from '../lib/imageProcess';
import { storePicture } from '../lib/pictures';
import { publicUrl } from '../lib/market';
import { Alert, Button } from './ui';

export function PictureEditor({ kind, ownerId, folder, currentPath, title, onSaved, onRemove }: {
  kind: FrameName; ownerId: string; folder: string; currentPath: string | null; title: string;
  onSaved: (path: string) => Promise<void> | void; onRemove?: () => Promise<void> | void;
}) {
  const { t, has } = useI18n();
  const frame = FRAMES[kind];
  const explain = (err: unknown) => {
    const key = `market.pic.err.${(err as Error).message}`;
    return has(key) ? t(key) : t('market.pic.err.failed');
  };
  const canvas = useRef<HTMLCanvasElement>(null);
  const [bitmap, setBitmap] = useState<ImageBitmap | null>(null);
  const [crop, setCrop] = useState<CropState>(DEFAULT_CROP);
  const [file, setFile] = useState<Blob | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);
  const current = publicUrl(currentPath);
  const aspect = frame.width / frame.height;

  // Redraws the preview whenever the picture or the crop changes.
  useEffect(() => {
    if (bitmap && canvas.current) drawFrame(canvas.current, bitmap, frame, crop);
  }, [bitmap, crop, frame]);

  useEffect(() => () => bitmap?.close(), [bitmap]);

  const choose = async (e: ChangeEvent<HTMLInputElement>) => {
    const picked = e.target.files?.[0];
    e.target.value = '';
    if (!picked) return;
    setError(null);
    setSaved(false);
    try {
      checkImageFile(picked);
      const decoded = await decodeImage(picked);
      setBitmap(decoded);
      setFile(picked);
      setCrop(DEFAULT_CROP);
    } catch (err) {
      setError(explain(err));
    }
  };

  const save = async () => {
    if (!file) return;
    setBusy(true);
    setError(null);
    try {
      const stored = await storePicture({ folder, kind, file, crop, ownerId });
      await onSaved(stored.path);
      setBitmap(null);
      setFile(null);
      setSaved(true);
    } catch (err) {
      setError(explain(err));
    } finally {
      setBusy(false);
    }
  };

  const remove = async () => {
    if (!onRemove) return;
    setBusy(true);
    try {
      await onRemove();
      setSaved(true);
    } catch {
      setError(t('market.pic.err.failed'));
    } finally {
      setBusy(false);
    }
  };

  return (
    <section aria-labelledby={`pic-${kind}`} className="space-y-3">
      <h3 id={`pic-${kind}`} className="font-bold">{title}</h3>
      <div className="flex flex-col gap-4 sm:flex-row sm:items-start">
        <div className="w-full sm:w-72" style={{ aspectRatio: String(aspect) }}>
          {bitmap ? (
            <canvas ref={canvas} role="img" aria-label={t('market.pic.preview')}
              className="h-full w-full rounded-2xl bg-gray-100 object-cover ring-1 ring-gray-200 dark:bg-gray-800 dark:ring-gray-700" />
          ) : current ? (
            <img src={current} alt={t('market.pic.current')} className="h-full w-full rounded-2xl bg-gray-100 object-cover ring-1 ring-gray-200 dark:bg-gray-800 dark:ring-gray-700" />
          ) : (
            <div className="flex h-full w-full items-center justify-center rounded-2xl border-2 border-dashed border-gray-300 text-sm text-ink-muted dark:border-gray-700">
              {t('market.pic.none')}
            </div>
          )}
        </div>
        <div className="min-w-0 flex-1 space-y-3">
          <p className="text-xs text-ink-muted">{t('market.pic.hint')}</p>
          <label className="inline-flex min-h-11 cursor-pointer items-center gap-2 rounded-xl border border-gray-300 px-4 text-sm font-semibold hover:bg-gray-50 focus-within:ring-2 focus-within:ring-brand-500 dark:border-gray-700 dark:hover:bg-gray-800">
            <ImagePlus className="h-4 w-4" />
            {current || bitmap ? t('market.pic.change') : t('market.pic.choose')}
            <input type="file" accept="image/png,image/jpeg,image/webp" className="sr-only" onChange={choose} disabled={busy} aria-label={t('market.pic.choose')} />
          </label>
          {bitmap && (
            <div className="space-y-3">
              <label className="block text-sm font-medium">{t('market.pic.zoom')}
                <input type="range" min={1} max={4} step={0.01} value={crop.zoom} onChange={(e) => setCrop({ ...crop, zoom: Number(e.target.value) })}
                  className="mt-1 w-full accent-brand-700" />
              </label>
              <label className="block text-sm font-medium">{t('market.pic.moveX')}
                <input type="range" min={-1} max={1} step={0.01} value={crop.offsetX} onChange={(e) => setCrop({ ...crop, offsetX: Number(e.target.value) })}
                  className="mt-1 w-full accent-brand-700" />
              </label>
              <label className="block text-sm font-medium">{t('market.pic.moveY')}
                <input type="range" min={-1} max={1} step={0.01} value={crop.offsetY} onChange={(e) => setCrop({ ...crop, offsetY: Number(e.target.value) })}
                  className="mt-1 w-full accent-brand-700" />
              </label>
              <div className="flex flex-wrap gap-2">
                <Button onClick={save} loading={busy} disabled={!file}>{t('market.pic.save')}</Button>
                <Button variant="ghost" onClick={() => { setBitmap(null); setFile(null); setError(null); }} disabled={busy}>{t('common.cancel')}</Button>
              </div>
            </div>
          )}
          {!bitmap && onRemove && current && (
            <Button variant="outline" icon={<Trash2 className="h-4 w-4" />} onClick={remove} loading={busy}>{t('market.pic.remove')}</Button>
          )}
          {saved && !bitmap && <Alert tone="green">{t('market.pic.saved')}</Alert>}
          {error && <Alert tone="red">{error}</Alert>}
        </div>
      </div>
    </section>
  );
}
