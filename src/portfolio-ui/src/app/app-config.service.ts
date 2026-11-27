import { HttpClient } from '@angular/common/http';
import { Injectable, inject } from '@angular/core';
import { firstValueFrom } from 'rxjs';

/**
 * Runtime settings, loaded once before the app starts (see app.config.ts).
 * The same container image runs everywhere; only /config.json differs:
 *   local:  { apiBase: "" }                                         -> calls /api on the same origin
 *   AKS:    { apiBase: "https://apim-portfolio-bab01.azure-api.net/portfolio" } -> calls go through API Management
 */
@Injectable({ providedIn: 'root' })
export class AppConfigService {
  private readonly http = inject(HttpClient);
  apiBase = '';

  async load(): Promise<void> {
    try {
      const cfg = await firstValueFrom(this.http.get<{ apiBase?: string }>('/config.json'));
      this.apiBase = (cfg.apiBase ?? '').replace(/\/+$/, '');
    } catch {
      this.apiBase = ''; // e.g. ng serve without the API: fall back to same origin
    }
  }
}
