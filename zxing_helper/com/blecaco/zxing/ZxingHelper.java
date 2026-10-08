package com.blecaco.zxing;

import com.google.zxing.BarcodeFormat;
import com.google.zxing.BinaryBitmap;
import com.google.zxing.DecodeHintType;
import com.google.zxing.RGBLuminanceSource;
import com.google.zxing.Result;
import com.google.zxing.common.HybridBinarizer;
import com.google.zxing.qrcode.QRCodeReader;

import java.util.Collections;
import java.util.EnumMap;
import java.util.Map;

public class ZxingHelper {

public static String ping() {
    return "ZXing OK";
}

public static String scanQR(byte[] rgba, int width, int height) {
    int pixelCount = width * height;

    if (rgba == null || rgba.length < pixelCount * 4) {
        return "";
    }

    int[] pixels = new int[pixelCount];

    for (int i = 0; i < pixelCount; i++) {
        int p = i * 4;

        int r = rgba[p] & 0xff;
        int g = rgba[p + 1] & 0xff;
        int b = rgba[p + 2] & 0xff;
        int a = rgba[p + 3] & 0xff;

        pixels[i] =
                (a << 24) |
                (r << 16) |
                (g << 8) |
                b;
    }

    RGBLuminanceSource source =
            new RGBLuminanceSource(width, height, pixels);

    BinaryBitmap bitmap =
            new BinaryBitmap(new HybridBinarizer(source));

    Map<DecodeHintType, Object> hints =
            new EnumMap<>(DecodeHintType.class);

    hints.put(
            DecodeHintType.POSSIBLE_FORMATS,
            Collections.singletonList(BarcodeFormat.QR_CODE)
    );

    try {
        Result result =
                new QRCodeReader().decode(bitmap, hints);

        return result.getText();

    } catch (Exception e) {
        return "";
    }
}

}
