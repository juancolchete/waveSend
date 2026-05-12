import { CapacitorConfig } from '@capacitor/cli';

const config: CapacitorConfig = {
  appId: 'com.yourname.app',
  appName: 'YourApp',
  webDir: 'out', // Must match the Next.js export folder
  bundledWebRuntime: false
};

export default config;
