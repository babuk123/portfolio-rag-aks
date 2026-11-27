import { ApplicationConfig, inject, provideAppInitializer, provideBrowserGlobalErrorListeners } from '@angular/core';
import { AppConfigService } from './app-config.service';
import { provideHttpClient, withFetch } from '@angular/common/http';

export const appConfig: ApplicationConfig = {
  providers: [
    provideBrowserGlobalErrorListeners(),
    provideHttpClient(withFetch()),
    // Load /config.json (API Management URL on AKS) before the first API call.
    provideAppInitializer(() => inject(AppConfigService).load()),
  ],
};
