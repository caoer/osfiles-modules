{ fetchzip }:

# sing-box's own web dashboard (SagerNet/sing-box-dashboard), the gh-pages
# build of main f231354. Served by the sing-box `api` service at /dashboard/
# from dashboard.path; a directory without sing-box's .etag file is served
# as-is, so this store path never self-updates. Bump: point rev at a newer
# gh-pages commit and refresh the hash.
fetchzip {
  name = "sing-box-dashboard-edca5a8";
  url = "https://github.com/SagerNet/sing-box-dashboard/archive/edca5a83ccd91f474d7942b990b360e12292b4a8.tar.gz";
  hash = "sha256-sSq6Ai4JR4fxIrLTsQJz5jg/S8XbgQtvcOM5xlxEmfA=";
}
