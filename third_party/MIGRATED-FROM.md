# 迁移来源 (老项目 ReSukiSU-Ultra-Kernel)
- adios/14-adios.patch                 <- patches/04-block-io/14-adios.patch  (patches.py: apply_adios, config.yaml features.adios)
- unicode_bypass/unicode_bypass_fix_6.1+.patch <- patches/09-android/unicode_bypass_fix_6.1+.patch (patches.py: apply_unicode_bypass, features.unicode_bypass)

集成方式见 scripts/ci-integrate.sh 的 stage_adios() / stage_unicode_bypass()。