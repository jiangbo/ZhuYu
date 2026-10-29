import com.reandroid.apk.ApkModule;
import com.reandroid.apk.xmlencoder.XMLEncodeSource;
import com.reandroid.archive.FileInputSource;
import com.reandroid.archive.writer.ApkFileWriter;
import com.reandroid.archive.writer.ZipAligner;
import com.reandroid.arsc.chunk.PackageBlock;
import com.reandroid.arsc.chunk.TableBlock;
import com.reandroid.arsc.coder.xml.XmlCoder;
import com.reandroid.xml.XMLDocument;
import com.reandroid.xml.source.XMLFileParserSource;

import java.io.File;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Iterator;
import java.util.stream.Stream;
import java.util.zip.ZipEntry;

// 仅处理引擎生成的资源，APK 生成和对齐全部使用 Java 库。
public class Apk {
    // 参数依次为资源目录、动态库、ABI、assets、两种压缩开关和输出路径。
    public static void main(String[] args) throws Exception {
        File root = new File(args[0]);
        XMLDocument manifest = XMLDocument.load(new File(root, "AndroidManifest.xml"));
        boolean compressLib = Boolean.parseBoolean(args[4]);
        boolean compressAssets = Boolean.parseBoolean(args[5]);
        try (ApkModule apk = new ApkModule()) {
            TableBlock table = new TableBlock();
            apk.setTableBlock(table);
            String name = manifest.getDocumentElement().getAttributeValue("package");
            PackageBlock pkg = table.newPackage(0x7f, name);
            table.setCurrentPackage(pkg);
            apk.initializeAndroidFramework(manifest);

            // 预先登记资源名称，再编码引用这些名称的 XML。
            pkg.getOrCreate("", "color", "ic_launcher_background");
            XmlCoder.getInstance().VALUES_XML.encode(
                new File(root, "res/values/colors.xml"), pkg);
            pkg.getOrCreate("-xxxhdpi", "mipmap", "ic_launcher_foreground")
                .setValueAsString("res/mipmap-xxxhdpi/ic_launcher_foreground.png");
            pkg.getOrCreate("-anydpi-v26", "mipmap", "ic_launcher")
                .setValueAsString("res/mipmap-anydpi-v26/ic_launcher.xml");
            addFile(apk, new File(root,
                "res/mipmap-xxxhdpi/ic_launcher_foreground.png"),
                "res/mipmap-xxxhdpi/ic_launcher_foreground.png", true);
            addXml(apk, pkg, root, "res/mipmap-anydpi-v26/ic_launcher.xml");
            addXml(apk, pkg, root, "AndroidManifest.xml");
            table.refreshFull();

            // 原生库和 assets 分别使用游戏选择的压缩方式。
            File lib = new File(args[1]);
            addFile(apk, lib, "lib/" + args[2] + "/" + lib.getName(), compressLib);
            Path assets = new File(args[3]).toPath();
            try (Stream<Path> paths = Files.walk(assets)) {
                Iterator<Path> files = paths.filter(Files::isRegularFile)
                    .sorted().iterator();
                while (files.hasNext()) {
                    Path file = files.next();
                    String path = assets.relativize(file).toString().replace('\\', '/');
                    addFile(apk, file.toFile(), "assets/" + path, compressAssets);
                }
            }
            apk.setExtractNativeLibs(compressLib);
            apk.getZipEntryMap().autoSortApkFiles();

            // 覆盖库默认的 4 KiB 对齐，未压缩的 .so 使用 16 KiB。
            ZipAligner aligner = new ZipAligner();
            aligner.setDefaultAlignment(4);
            aligner.setFileAlignment(ZipAligner.PREDICATE_NATIVE_LIBS, 16384);
            ApkFileWriter writer = apk.createApkFileWriter(new File(args[6]));
            writer.setZipAligner(aligner);
            writer.write();
        }
    }

    // XML 按包内资源表编码，Manifest 和资源表都保持未压缩。
    private static void addXml(ApkModule apk, PackageBlock pkg, File root,
                               String path) {
        XMLEncodeSource source = new XMLEncodeSource(pkg,
            new XMLFileParserSource(path, new File(root, path)));
        source.setMethod(ZipEntry.STORED);
        apk.add(source);
        apk.getUncompressedFiles().addPath(source);
    }

    // 普通文件直接写入 APK，路径始终使用 ZIP 的斜杠格式。
    private static void addFile(ApkModule apk, File file, String path,
                                boolean compress) {
        FileInputSource source = new FileInputSource(file, path);
        source.setMethod(compress ? ZipEntry.DEFLATED : ZipEntry.STORED);
        apk.add(source);
        if (!compress) apk.getUncompressedFiles().addPath(source);
    }
}
