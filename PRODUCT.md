# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Stack

Existing codebase: single-file static `index.html` (Tailwind CDN + vanilla JS) with `config.js`, deployed on Vercel from GitHub; backend is Supabase RPC (`supabase/001_backend.sql`). Thai language UI. Stack stays; no framework migration.

## Users

Three groups of roughly equal weight, confirmed by the owner:
- Hospital executives (ผู้บริหาร) viewing an overview/dashboard on a large screen, including during a presentation.
- Supply/asset officers (เจ้าหน้าที่พัสดุ) doing registry, approval, handover, return, repair and report work on desktop computers.
- Nurses and ward staff (พยาบาล/บุคลากร) borrowing and returning equipment on mobile phones at the point of work.

## Product Purpose

Central equipment (ครุภัณฑ์) loan system for โรงพยาบาลสันทราย: request → approve → hand over → return, repairs, disposal, QR lookup, official-style reports and Excel export. Success: staff can find and borrow equipment in a few taps, officers keep an accurate registry, executives see status at a glance.

## Positioning

An in-house tool built by the hospital's own developer for โรงพยาบาลสันทราย, replacing a generic template. It must look and feel clearly like this hospital's own system and must not be mistaken for the original template it was derived from.

## Operating Context

Thai-language, official-document conventions (Buddhist-era dates, หนังสือ/บันทึกข้อความ print previews, A4). Used on hospital desktops, wall/large screens for presentations, and phones on wards. Roles: SuperAdmin, DeptAdmin, Approver, Borrower.

## Capabilities and Constraints

- All existing functions and routes stay (catalog, QR scan, my borrows, approvals, summaries, assets, maintenance, disposals, departments, users, reports, settings).
- Backend contract (16 RPCs) must not change.
- A simulated-data demo mode is required for executive presentations: entered by a "ทดลองโหมดจำลอง" button on the login screen; uses fictional data only, never touches the real database, and is clearly labelled as simulated.
- Hospital logo is not available yet; the owner will upload it in Settings later. The UI must look finished without a logo and show it when present.

## Brand Commitments

- Name: โรงพยาบาลสันทราย. No hospital brand colors exist; palette, type and style are free to design (confirmed). The design must be visibly different from the template's indigo/zinc card look.

## Evidence on Hand

No real equipment data, photos or logo yet. Demo data must be plainly fictional.

## Product Principles

1. Mobile staff flow first-class: borrowing must be comfortable one-handed.
2. Executives read status in seconds: the overview leads with what needs attention.
3. Officers get dense, scannable, keyboard-friendly work surfaces.
4. Never confuse demo data with real data.
