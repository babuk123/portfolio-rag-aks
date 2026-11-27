import { HttpClient } from '@angular/common/http';
import { Injectable, inject } from '@angular/core';
import { Observable } from 'rxjs';
import { AppConfigService } from './app-config.service';
import { ChatResponse, ChatTurn, CustomerListItem, Portfolio, Review } from './models';

/**
 * All calls go to `${apiBase}/api/...`. apiBase comes from /config.json at startup:
 * empty locally (dev proxy), the API Management gateway URL on AKS.
 */
@Injectable({ providedIn: 'root' })
export class ApiService {
  private readonly http = inject(HttpClient);
  private readonly config = inject(AppConfigService);
  private get base(): string {
    return this.config.apiBase;
  }

  customers(): Observable<CustomerListItem[]> {
    return this.http.get<CustomerListItem[]>(`${this.base}/api/customers`);
  }

  portfolio(customerId: string): Observable<Portfolio> {
    return this.http.get<Portfolio>(`${this.base}/api/customers/${customerId}`);
  }

  reviews(customerId: string): Observable<Review[]> {
    return this.http.get<Review[]>(`${this.base}/api/customers/${customerId}/reviews`);
  }

  requestReview(customerId: string, requestedBy: string, advisorNotes: string): Observable<Review> {
    return this.http.post<Review>(`${this.base}/api/customers/${customerId}/reviews`, { requestedBy, advisorNotes });
  }

  indexSamplePolicy(): Observable<{ blobName: string; chunks: number }> {
    return this.http.post<{ blobName: string; chunks: number }>(`${this.base}/api/documents/sample-policy`, {});
  }

  ask(customerId: string, question: string, history: ChatTurn[]): Observable<ChatResponse> {
    return this.http.post<ChatResponse>(`${this.base}/api/chat`, { customerId, question, history });
  }

  reviewPdfUrl(reviewId: string): string {
    return `${this.base}/api/reviews/${reviewId}/pdf`;
  }

  fileUrl(blobName: string): string {
    return `${this.base}/api/files?blobName=${encodeURIComponent(blobName)}`;
  }
}
