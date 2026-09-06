// Rebuild native PNGs from authored SVGs. Optional argv[2] is a Sharp module
// path for environments that bundle it outside the project dependencies.
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const sharp = (await import(process.argv[2] || 'sharp')).default;
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const icon = await fs.readFile(path.join(root, 'assets/branding/luffi-app-icon.svg'));
const mark = await fs.readFile(path.join(root, 'assets/branding/luffi-mark.svg'));
const render = (source, size, destination) => sharp(source)
  .resize(size, size)
  .png()
  .toFile(path.join(root, destination));

await render(icon, 1024, 'assets/branding/luffi-app-icon.png');
for (const [density, size] of Object.entries({mdpi: 48, hdpi: 72, xhdpi: 96, xxhdpi: 144, xxxhdpi: 192})) {
  await render(icon, size, `android/app/src/main/res/mipmap-${density}/ic_launcher.png`);
}
const iosDirectory = 'ios/Runner/Assets.xcassets/AppIcon.appiconset';
const iosContents = JSON.parse(await fs.readFile(path.join(root, iosDirectory, 'Contents.json'), 'utf8'));
for (const entry of iosContents.images) {
  if (!entry.filename) continue;
  const size = Math.round(Number(entry.size.split('x')[0]) * Number(entry.scale.replace('x', '')));
  await render(icon, size, `${iosDirectory}/${entry.filename}`);
}
for (const [suffix, scale] of [['', 1], ['@2x', 2], ['@3x', 3]]) {
  await render(mark, 88 * scale, `ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage${suffix}.png`);
}
console.log('Rendered luffi icon, Android density assets, iOS icons, and launch marks.');
