import { defineConfig, devices } from '@playwright/test';

const baseURL = 'http://127.0.0.1:4517';

export default defineConfig({
  testDir: 'e2e',
  fullyParallel: false,
  workers: 1,
  reporter: 'list',
  use: { baseURL },
  webServer: {
    command: 'node scripts/serve-static.mjs',
    url: baseURL,
    reuseExistingServer: false,
    timeout: 30_000,
  },
  projects: [
    { name: 'chromium-390', use: { ...devices['Desktop Chrome'], viewport: { width: 390, height: 844 } } },
    { name: 'chromium-1440', use: { ...devices['Desktop Chrome'], viewport: { width: 1440, height: 900 } } },
    { name: 'webkit-390', use: { ...devices['Desktop Safari'], viewport: { width: 390, height: 844 } } },
    { name: 'webkit-1440', use: { ...devices['Desktop Safari'], viewport: { width: 1440, height: 900 } } },
  ],
});
