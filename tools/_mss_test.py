import mss, numpy as np, cv2, os
s = mss.mss()
mon = s.monitors[1]  # primary monitor
img = np.array(s.grab(mon), dtype=np.uint8)  # BGRA
img = cv2.cvtColor(img, cv2.COLOR_BGRA2BGR)
os.makedirs(r'D:\Echo\state', exist_ok=True)
cv2.imwrite(r'D:\Echo\state\_mss_test.png', img)
print('wrote D:\\Echo\\state\\_mss_test.png', img.shape)
