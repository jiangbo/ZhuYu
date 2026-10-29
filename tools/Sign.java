import com.android.apksig.ApkSigner;
import com.android.apksig.KeyConfig;

import java.io.File;
import java.io.FileInputStream;
import java.security.KeyStore;
import java.security.PrivateKey;
import java.security.cert.Certificate;
import java.security.cert.X509Certificate;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

// 直接调用官方签名 API，使用 JDK 的密码提供者，无需原生 Conscrypt。
public class Sign {
    // 参数依次为待签名 APK、输出 APK 和现有调试密钥。
    public static void main(String[] args) throws Exception {
        KeyStore store = KeyStore.getInstance("JKS");
        try (FileInputStream input = new FileInputStream(args[2])) {
            store.load(input, "android".toCharArray());
        }
        PrivateKey key = (PrivateKey) store.getKey(
            "androiddebugkey", "android".toCharArray());
        List<X509Certificate> certificates = new ArrayList<>();
        for (Certificate certificate : store.getCertificateChain("androiddebugkey")) {
            certificates.add((X509Certificate) certificate);
        }
        ApkSigner.SignerConfig signer = new ApkSigner.SignerConfig.Builder(
            "ZhuYu", new KeyConfig.Jca(key), certificates).build();
        // 最低 API 从 Manifest 读取，签名算法及兼容处理由官方库决定。
        new ApkSigner.Builder(Collections.singletonList(signer))
            .setInputApk(new File(args[0]))
            .setOutputApk(new File(args[1]))
            .setV4SigningEnabled(false)
            .build().sign();
    }
}
