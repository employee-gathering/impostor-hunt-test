PAKET PERUBAHAN AWAL CIH — 18 NOVEMBER 2026

Isi paket:
1. admin-dashboard.html
   - Dashboard awal dengan autentikasi Supabase Auth.
   - Otorisasi memakai satu sumber: RPC ih_is_admin() yang memeriksa admin_users.
   - Statistik dan daftar peserta dibaca dinamis dari attendees, ih_teams, ih_team_members, ih_game_sessions.
   - Tidak ada angka peserta tetap.
   - Tahap ini masih READ-ONLY. Fitur tambah/edit/nonaktifkan/pindah tim belum diaktifkan karena RPC CRUD admin belum ada di migration yang diperiksa dan skema lengkap tabel attendees belum diverifikasi.

2. 20261117_001_cih_simplified_participant_flow.sql
   - Migration alur peserta TIM + NID dan satu jenis Admin.
   - Tidak berisi daftar peserta atau NID pribadi.
   - Harus ditinjau dan diuji di staging sebelum diterapkan.

PENTING:
- Jangan unggah file PRIVATE_20261117_002_cih_participant_import.sql ke repository publik. File tersebut berisi NID peserta.
- Jangan jalankan migration pada database produksi sebelum backup dan uji staging.
- Dashboard mengasumsikan tabel attendees memiliki kolom id, full_name, nid, batch, active; dan RPC ih_is_admin() tersedia setelah migration diterapkan.
- File dashboard ini adalah tahap awal baca data, bukan keseluruhan CRUD Admin.

CARA UNGGAH KE GITHUB DENGAN AMAN:
1. Buka repository employee-gathering/impostor-hunt-test.
2. Buat branch baru bernama cih-admin-unified dari main.
3. Pada branch tersebut, pilih Add file > Upload files.
4. Unggah admin-dashboard.html dan file migration SQL.
5. Commit dengan pesan: Add initial unified CIH admin dashboard.
6. Jangan merge ke main dulu. Periksa hasil branch terlebih dahulu.
